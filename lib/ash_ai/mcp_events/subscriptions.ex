# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Subscriptions do
  @moduledoc """
  `events/list`, `events/subscribe` and `events/unsubscribe` (BLENDED-026), as Oberon's
  `Subscriptions` answers them (`src/events.ts`), over the storage of the server's event domains.

  Subscribe checks, in Oberon's order: the params' shape, the event and its arguments, the
  delivery mode, the secret, the URL (an `https` URL, else `-32015` `invalid_url`); then computes
  the id, verifies the callback through the sender unless the same principal verified the same
  URL within 24 h, and creates or refreshes the row. A refresh keeps the cursor; a changed secret
  opens a 1 h rotation window in which both secrets sign. Anonymous callers are refused.
  """

  require Ash.Query

  alias AshAi.McpEvents
  alias AshAi.McpEvents.{ActorPersister, Catalog}

  @type error :: {:error, integer(), String.t(), map() | nil}

  @doc "The event domains of a server: the `events` option, else the `otp_app`'s domains with storage."
  @spec domains(keyword()) :: [module()]
  def domains(opts) do
    case Keyword.get(opts, :events) do
      false ->
        []

      domains when is_list(domains) ->
        Enum.filter(domains, &Catalog.storage/1)

      nil ->
        case opts[:otp_app] do
          nil ->
            []

          otp_app ->
            otp_app |> Application.get_env(:ash_domains, []) |> Enum.filter(&Catalog.storage/1)
        end
    end
  end

  @doc "Every event the server serves, with its domain; an event name served twice raises."
  @spec catalog(keyword()) :: [{module(), AshAi.McpEvent.t()}]
  def catalog(opts) do
    entries = for domain <- domains(opts), event <- Catalog.events(domain), do: {domain, event}

    entries
    |> Enum.group_by(fn {_domain, event} -> event.name end)
    |> Enum.find(fn {_name, entries} -> length(entries) > 1 end)
    |> case do
      nil ->
        entries

      {name, clashing} ->
        raise ArgumentError,
              "MCP event #{inspect(name)} is served by #{Enum.map_join(clashing, " and ", &inspect(elem(&1, 0)))}; event names must be unique on a server"
    end
  end

  @doc "The `events/list` result."
  @spec list(keyword()) :: map()
  def list(opts) do
    %{"events" => Enum.map(catalog(opts), fn {_domain, event} -> Catalog.definition(event) end)}
  end

  @doc "The `events/subscribe` result, or a JSON-RPC error."
  @spec subscribe(term(), keyword()) :: {:ok, map()} | error()
  def subscribe(params, opts) do
    with {:ok, principal} <- principal(opts, "events/subscribe"),
         {:ok, params} <- subscribe_params(params),
         {:ok, domain, event} <- find_event(params.name, opts),
         {:ok, arguments} <- arguments(event, params.arguments),
         :ok <- webhook_mode(params.mode),
         :ok <- secret(params.secret),
         {:ok, url} <- https_url(params.url) do
      storage = Catalog.storage(domain)
      id = McpEvents.subscription_id(principal, url, event.name, arguments)

      with {:ok, verified_at} <- verify(storage, principal, url, id, params.secret, opts),
           {:ok, requester} <- requester(storage, opts[:actor]) do
        upsert(storage, event, %{
          id: id,
          principal: principal,
          url: url,
          arguments: arguments,
          secret: params.secret,
          ttl: params.ttl,
          verified_at: verified_at,
          requester: requester,
          server_url: opts[:server_url]
        })
      end
    end
  end

  @doc "The `events/unsubscribe` result (`{}`, idempotent), or a JSON-RPC error."
  @spec unsubscribe(term(), keyword()) :: {:ok, map()} | error()
  def unsubscribe(params, opts) do
    with {:ok, principal} <- principal(opts, "events/unsubscribe"),
         {:ok, params} <- unsubscribe_params(params),
         {:ok, domain, event} <- find_event(params.name, opts),
         {:ok, arguments} <- arguments(event, params.arguments),
         :ok <- webhook_mode(params.mode),
         {:ok, url, _uri} <- parse_url(params.url) do
      storage = Catalog.storage(domain)
      id = McpEvents.subscription_id(principal, url, event.name, arguments)

      case get(storage, id) do
        nil ->
          {:ok, %{}}

        subscription ->
          Ash.destroy!(subscription,
            action: :unsubscribe,
            authorize?: false,
            domain: storage.domain
          )

          {:ok, %{}}
      end
    end
  end

  ## Checks

  defp principal(opts, method) do
    case McpEvents.principal(opts[:actor]) do
      nil -> invalid_request("#{method} requires an authenticated caller")
      principal -> {:ok, principal}
    end
  end

  defp subscribe_params(%{} = params) do
    with {:ok, name} <- string_param(params, "name"),
         {:ok, arguments} <- arguments_param(params),
         {:ok, delivery} <- delivery_param(params),
         {:ok, mode} <- string_param(delivery, "mode", "delivery.mode"),
         {:ok, url} <- string_param(delivery, "url", "delivery.url"),
         {:ok, secret} <- string_param(delivery, "secret", "delivery.secret"),
         :ok <- cursor_param(params),
         {:ok, ttl} <- ttl_param(params) do
      {:ok, %{name: name, arguments: arguments, mode: mode, url: url, secret: secret, ttl: ttl}}
    end
  end

  defp subscribe_params(_params), do: invalid_params("Invalid params: params must be an object")

  defp unsubscribe_params(%{} = params) do
    with {:ok, name} <- string_param(params, "name"),
         {:ok, arguments} <- arguments_param(params),
         {:ok, delivery} <- delivery_param(params),
         {:ok, mode} <- string_param(delivery, "mode", "delivery.mode"),
         {:ok, url} <- string_param(delivery, "url", "delivery.url") do
      {:ok, %{name: name, arguments: arguments, mode: mode, url: url}}
    end
  end

  defp unsubscribe_params(_params), do: invalid_params("Invalid params: params must be an object")

  defp string_param(map, key, label \\ nil) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> invalid_params("Invalid params: #{label || key} must be a string")
    end
  end

  defp arguments_param(params) do
    case Map.get(params, "arguments", %{}) do
      %{} = arguments -> {:ok, arguments}
      nil -> {:ok, %{}}
      _ -> invalid_params("Invalid params: arguments must be an object")
    end
  end

  defp delivery_param(params) do
    case Map.get(params, "delivery") do
      %{} = delivery -> {:ok, delivery}
      _ -> invalid_params("Invalid params: delivery must be an object")
    end
  end

  defp cursor_param(params) do
    case Map.get(params, "cursor") do
      value when is_nil(value) or is_binary(value) -> :ok
      _ -> invalid_params("Invalid params: cursor must be a string or null")
    end
  end

  defp ttl_param(params) do
    case Map.fetch(params, "ttlMs") do
      :error -> {:ok, :omitted}
      {:ok, nil} -> {:ok, nil}
      {:ok, ms} when is_integer(ms) and ms > 0 -> {:ok, ms}
      {:ok, _} -> invalid_params("Invalid params: ttlMs must be a positive integer or null")
    end
  end

  defp find_event(name, opts) do
    case Enum.find(catalog(opts), fn {_domain, event} -> event.name == name end) do
      nil -> invalid_params("Unknown event: #{name}")
      {domain, event} -> {:ok, domain, event}
    end
  end

  defp arguments(event, arguments) do
    case Catalog.normalize_arguments(event, arguments) do
      {:ok, arguments} -> {:ok, arguments}
      {:error, message} -> invalid_params("Invalid arguments for #{event.name}: #{message}")
    end
  end

  defp webhook_mode("webhook"), do: :ok
  defp webhook_mode(_mode), do: invalid_params("Only webhook delivery is supported")

  defp secret(secret) do
    if McpEvents.valid_secret?(secret) do
      :ok
    else
      invalid_params(
        "delivery.secret must be a whsec_ secret whose base64 value decodes to 24–64 bytes"
      )
    end
  end

  defp https_url(url) do
    with {:ok, url, uri} <- parse_url(url) do
      if uri.scheme == "https" do
        {:ok, url}
      else
        {:error, McpEvents.callback_endpoint_error(), "Callback URL must use https",
         %{"reason" => "invalid_url"}}
      end
    end
  end

  defp parse_url(url) do
    case McpEvents.normalize_url(url) do
      {:ok, url, uri} -> {:ok, url, uri}
      {:error, :invalid} -> invalid_params("delivery.url is not a valid URL")
    end
  end

  ## Verification (Oberon `#verifyCallback`), cached per (principal, URL) on the subscription rows

  defp verify(storage, principal, url, id, secret, opts) do
    now = McpEvents.Clock.utc_now()
    since = McpEvents.add_ms(now, -McpEvents.verification_cache_ms())

    cached =
      storage.subscription
      |> Ash.Query.filter(principal == ^principal and url == ^url and verified_at > ^since)
      |> Ash.Query.sort(verified_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false, domain: storage.domain)

    case cached do
      [%{verified_at: verified_at}] ->
        {:ok, verified_at}

      [] ->
        verification = %{
          server_url: opts[:server_url],
          principal: principal,
          url: url,
          subscription_id: id,
          secret: secret
        }

        case storage.sender.verify_callback(verification, storage.sender_options) do
          :ok ->
            {:ok, now}

          {:error, reason, message} ->
            {:error, McpEvents.callback_endpoint_error(), message, %{"reason" => reason}}
        end
    end
  end

  defp requester(storage, actor) do
    case ActorPersister.store(ActorPersister.for_storage(storage), actor) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, error} ->
        {:error, -32_603,
         "events/subscribe could not persist the caller for delivery: #{inspect(error)}", nil}
    end
  end

  ## The row

  defp upsert(storage, event, input) do
    now = McpEvents.Clock.utc_now()
    expires_at = McpEvents.add_ms(now, McpEvents.granted_ttl_ms(input.ttl))

    subscription =
      case get(storage, input.id) do
        %{state: :expired} = expired ->
          Ash.destroy!(expired, action: :unsubscribe, authorize?: false, domain: storage.domain)
          nil

        other ->
          other
      end

    case subscription do
      nil ->
        storage.subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            id: input.id,
            principal: input.principal,
            name: event.name,
            arguments: input.arguments,
            url: input.url,
            server_url: input.server_url,
            secrets: [input.secret],
            rotation_ends_at: nil,
            expires_at: expires_at,
            verified_at: input.verified_at,
            cursor: initial_cursor(storage, event, input.arguments, now),
            requester: input.requester
          },
          authorize?: false,
          domain: storage.domain
        )
        |> Ash.create!()

      existing ->
        [current | _] = existing.secrets
        rotating? = current != input.secret

        existing
        |> Ash.Changeset.for_update(
          :refresh,
          %{
            server_url: input.server_url,
            secrets: if(rotating?, do: [input.secret, current], else: existing.secrets),
            rotation_ends_at:
              if(rotating?,
                do: McpEvents.add_ms(now, McpEvents.rotation_window_ms()),
                else: existing.rotation_ends_at
              ),
            expires_at: expires_at,
            verified_at: input.verified_at,
            requester: input.requester
          },
          authorize?: false,
          domain: storage.domain
        )
        |> Ash.update!()
    end

    {:ok,
     %{
       "id" => input.id,
       "refreshBefore" => McpEvents.iso8601(expires_at),
       "cursor" => nil,
       "truncated" => false
     }}
  end

  # Catch-up (Oberon `catchUpSubscription`): a subscription that pins the record's primary key
  # starts 2 min back, so an event that fired moments before it was created reaches it (and only
  # it). Any other starts after every occurrence that already exists.
  defp initial_cursor(storage, event, arguments, now) do
    if Catalog.pins_primary_key?(event, arguments) do
      McpEvents.time_key(McpEvents.add_ms(now, -McpEvents.catch_up_window_ms()))
    else
      name = event.name

      latest =
        storage.occurrence
        |> Ash.Query.filter(name == ^name)
        |> Ash.Query.sort(sort_key: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false, domain: storage.domain)

      case latest do
        [%{sort_key: sort_key}] -> max(sort_key, McpEvents.time_key(now))
        [] -> McpEvents.time_key(now)
      end
    end
  end

  defp get(storage, id) do
    case Ash.get(storage.subscription, id,
           authorize?: false,
           domain: storage.domain,
           error?: false
         ) do
      {:ok, subscription} -> subscription
      _ -> nil
    end
  end

  defp invalid_params(message), do: {:error, McpEvents.invalid_params(), message, nil}
  defp invalid_request(message), do: {:error, -32_600, message, nil}
end
