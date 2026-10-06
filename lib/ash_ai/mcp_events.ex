# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents do
  @moduledoc """
  MCP Events (BLENDED-026): webhook events declared on resources, served by `AshAi.Mcp.Server`
  as `events/list`, `events/subscribe` and `events/unsubscribe` (OpenAI "MCP Events",
  protocol `2026-07-28`, as Oberon's reference server answers them).

  ## Declaring events

  A resource declares its events in the `mcp_events` section of the `AshAi` extension:

      mcp_events do
        event "ticket.closed" do
          description "A ticket was closed or rejected."
          states [:closed, :rejected]   # the resource's AshQueue space entered one of these
          filter [:id, :project_id]     # public attributes -> inputSchema (each optional)
          payload [:id, :title, :state] # public attributes -> payloadSchema (all required)
        end

        event "ticket.created" do
          action :create                # the action ran
        end
      end

  A domain names its event storage in its own `mcp_events` section:

      mcp_events do
        subscription MyApp.McpEventSubscription
        occurrence MyApp.McpEventOccurrence
        delivery MyApp.McpEventDelivery
      end

  In such a domain every AshQueue space of its resources also generates one event per terminal
  state, `<resource>.<space>.<state>` (`ticket.flow.closed`), filtered by the primary key, with the
  resource's public attributes as payload. A declared event with the same name replaces it.

  The storage resources are ordinary Ash resources with AshQueue spaces, written with
  `use AshAi.McpEvents.Subscription`, `use AshAi.McpEvents.Occurrence` and
  `use AshAi.McpEvents.Delivery`.

  ## How an event travels

  1. **Emission** (`AshAi.McpEvents.Changes.Emit`): a global change on the source resource's
     create and update actions writes one occurrence row in the writer's transaction when the
     space attribute moved into an event state, or when the event's action ran.
  2. **Collection** (`AshAi.McpEvents.Changes.Collect`): the subscription's automatic `collect`
     edge reads the occurrences after its cursor, matches its arguments against each
     occurrence's facts, reads the record through the primary read *as the subscriber*
     (`authorize?: true`; a record the subscriber cannot read is not delivered at all) and writes
     one delivery row per match, then advances the cursor.
  3. **Delivery** (`AshAi.McpEvents.Changes.Deliver`): the delivery's automatic `deliver` edge
     posts the frozen body through the domain's `AshAi.McpEvents.Sender`, signed with Standard
     Webhooks headers, retried after 1 s, 5 s, 30 s and 2 min, five attempts in all.

  The AshQueue sweep is the correctness path for every edge; reactive wakes are latency hints.
  """

  @default_ttl_ms 24 * 60 * 60 * 1000
  @min_ttl_ms 60 * 60 * 1000
  @max_ttl_ms 7 * 24 * 60 * 60 * 1000
  @verification_cache_ms 24 * 60 * 60 * 1000
  @rotation_window_ms 60 * 60 * 1000
  @retry_delays_ms [1_000, 5_000, 30_000, 120_000]
  @catch_up_window_ms 2 * 60 * 1000
  @max_event_bytes 256 * 1024
  @max_response_bytes 64 * 1024
  @send_timeout_ms 10_000
  @prune_after_ms 24 * 60 * 60 * 1000
  @collect_batch 64

  @callback_endpoint_error -32_015
  @invalid_params -32_602

  @doc "TTL granted when `ttlMs` is omitted (24 h)."
  def default_ttl_ms, do: @default_ttl_ms
  @doc "Shortest TTL granted (1 h)."
  def min_ttl_ms, do: @min_ttl_ms
  @doc "Longest TTL granted, also the grant for `ttlMs: null` (7 d)."
  def max_ttl_ms, do: @max_ttl_ms
  @doc "How long a successful callback verification is reused per (principal, URL) (24 h)."
  def verification_cache_ms, do: @verification_cache_ms
  @doc "How long both secrets sign after a refresh changed the secret (1 h)."
  def rotation_window_ms, do: @rotation_window_ms
  @doc "Delays before the 2nd..5th delivery attempt."
  def retry_delays_ms, do: @retry_delays_ms
  @doc "Delivery attempts in all."
  def max_attempts, do: length(@retry_delays_ms) + 1
  @doc "How far back a subscription that pins the record's primary key starts (2 min)."
  def catch_up_window_ms, do: @catch_up_window_ms
  @doc "Largest event body sent (256 KiB)."
  def max_event_bytes, do: @max_event_bytes
  @doc "Most of a callback response read (64 KiB)."
  def max_response_bytes, do: @max_response_bytes
  @doc "Callback request timeout (10 s)."
  def send_timeout_ms, do: @send_timeout_ms
  @doc "Occurrences are pruned this long after they occurred (24 h)."
  def prune_after_ms, do: @prune_after_ms
  @doc "Occurrences one `collect` run reads."
  def collect_batch, do: @collect_batch

  @doc "JSON-RPC error code of a callback endpoint failure (MCP Events draft)."
  def callback_endpoint_error, do: @callback_endpoint_error
  @doc false
  def invalid_params, do: @invalid_params

  @doc """
  JSON with object keys sorted at every depth and `nil` members dropped, so `{a,b}` and `{b,a}`
  identify the same subscription (Oberon `canonicalJson`).
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  def canonical_json(value) when is_map(value) and not is_struct(value) do
    members =
      value
      |> Enum.reject(fn {_key, member} -> is_nil(member) end)
      |> Enum.map(fn {key, member} -> {to_string(key), member} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, member} ->
        Jason.encode!(key) <> ":" <> canonical_json(member)
      end)

    "{" <> members <> "}"
  end

  def canonical_json(value), do: Jason.encode!(value)

  @doc """
  The subscription id: `sub_` and the first 32 hex digits of SHA-256 over the canonical JSON of
  `[principal, url, name, arguments]` (Oberon `subscriptionId`), so subscribing again refreshes.
  """
  @spec subscription_id(String.t(), String.t(), String.t(), map()) :: String.t()
  def subscription_id(principal, url, name, arguments) do
    digest =
      :crypto.hash(:sha256, canonical_json([principal, url, name, arguments]))
      |> Base.encode16(case: :lower)

    "sub_" <> binary_part(digest, 0, 32)
  end

  @doc "The delivery id of a (subscription, event) pair: a second write of the pair is the same row."
  @spec delivery_id(String.t(), String.t()) :: String.t()
  def delivery_id(subscription_id, event_id) do
    digest =
      :crypto.hash(:sha256, subscription_id <> " " <> event_id) |> Base.encode16(case: :lower)

    "dlv_" <> binary_part(digest, 0, 32)
  end

  @doc """
  A new event id: `evt_` and 32 hex digits, time-ordered (microseconds, then a node-monotonic
  counter, then random bits).
  """
  @spec event_id(DateTime.t()) :: String.t()
  def event_id(%DateTime{} = occurred_at) do
    micros = DateTime.to_unix(occurred_at, :microsecond)
    counter = rem(System.unique_integer([:positive, :monotonic]), 0x100000000)
    random = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

    "evt_" <> hex(micros, 14) <> hex(counter, 8) <> random
  end

  @doc """
  An occurrence's sort key: its time in microseconds, zero-padded, then its id's hex digits.
  Only digits and lower-case hex, so every collation orders it as bytes.
  """
  @spec sort_key(DateTime.t(), String.t()) :: String.t()
  def sort_key(%DateTime{} = occurred_at, "evt_" <> hex) do
    time_key(occurred_at) <> hex
  end

  @doc "A cursor at an instant: every occurrence at or after it sorts after the cursor."
  @spec time_key(DateTime.t()) :: String.t()
  def time_key(%DateTime{} = at) do
    at |> DateTime.to_unix(:microsecond) |> Integer.to_string() |> String.pad_leading(20, "0")
  end

  defp hex(value, digits) do
    value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(digits, "0")
  end

  @doc "The TTL granted for a requested `ttlMs` (omitted: 24 h; `nil`: 7 d; else clamped 1 h..7 d)."
  @spec granted_ttl_ms(:omitted | nil | pos_integer()) :: pos_integer()
  def granted_ttl_ms(:omitted), do: @default_ttl_ms
  def granted_ttl_ms(nil), do: @max_ttl_ms
  def granted_ttl_ms(ms) when is_integer(ms), do: ms |> max(@min_ttl_ms) |> min(@max_ttl_ms)

  @doc """
  Checks a `whsec_` secret: its base64 value must decode to 24..64 bytes.
  """
  @spec valid_secret?(term()) :: boolean()
  def valid_secret?("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> byte_size(bytes) in 24..64
      :error -> false
    end
  end

  def valid_secret?(_secret), do: false

  @doc """
  The principal of a caller: a digest of the actor's stable identity, the identity
  `AshAi.Page.session_id/2` uses. `nil` for an anonymous caller.
  """
  @spec principal(term()) :: String.t() | nil
  def principal(actor), do: AshAi.Page.session_id(actor, __MODULE__)

  @doc "An instant as JavaScript's `toISOString` writes it (milliseconds, `Z`)."
  @spec iso8601(DateTime.t()) :: String.t()
  def iso8601(%DateTime{} = at) do
    at
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  @doc "Adds milliseconds to an instant."
  @spec add_ms(DateTime.t(), integer()) :: DateTime.t()
  def add_ms(%DateTime{} = at, ms), do: DateTime.add(at, ms, :millisecond)

  @doc """
  A callback URL as the WHATWG URL parser writes it back (Oberon `new URL(url).href`) for the
  parts that matter to the subscription id: lower-case scheme and host, no default port, `/`
  for an empty path. `{:error, :invalid}` when it is not an absolute URL with a host.
  """
  @spec normalize_url(term()) :: {:ok, String.t(), URI.t()} | {:error, :invalid}
  def normalize_url(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)

        uri = %URI{
          uri
          | scheme: scheme,
            host: String.downcase(host),
            port: if(uri.port == URI.default_port(scheme), do: nil, else: uri.port),
            path: if(uri.path in [nil, ""], do: "/", else: uri.path)
        }

        {:ok, URI.to_string(uri), uri}

      _ ->
        {:error, :invalid}
    end
  end

  def normalize_url(_url), do: {:error, :invalid}
end
