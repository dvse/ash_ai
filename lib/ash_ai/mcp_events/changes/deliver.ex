# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Changes.Deliver do
  @moduledoc """
  The body of a delivery's `deliver` edge (BLENDED-026, design §6), an effect outside any
  transaction; Oberon's `#deliverOne`, one attempt per job attempt:

  | Outcome | Result |
  |---|---|
  | subscription gone or expired | `failed` ("subscription ended"), no request |
  | `2xx` | `delivered` |
  | `410` | the subscription is destroyed; `failed` |
  | `413`, or `4xx` other than `408`/`429` | `failed`, not retried |
  | other status, network error, timeout | an error: the queue retries after the next delay |

  The active secrets are computed per attempt: both during a rotation window, then the newest.
  """

  use Ash.Resource.Change

  require Logger

  alias AshAi.McpEvents
  alias AshAi.McpEvents.Catalog

  @doc """
  The backoff before the next attempt, in seconds (AshQueue's unit): 1, 5, 30, 120 after the
  1st..4th failed attempt. Emits `[:ash_ai, :mcp_events, :retry]` with `%{delay_ms: ms}`.
  """
  def backoff(job) do
    attempt = Map.get(job, :attempt) || 1
    delays = McpEvents.retry_delays_ms()
    delay_ms = Enum.at(delays, min(attempt, length(delays)) - 1)

    :telemetry.execute([:ash_ai, :mcp_events, :retry], %{delay_ms: delay_ms}, %{
      attempt: attempt,
      job_id: Map.get(job, :id)
    })

    div(delay_ms, 1000)
  end

  @impl true
  def change(changeset, _opts, _context) do
    delivery = changeset.data
    storage = Catalog.storage_for_resource!(changeset.resource)
    now = McpEvents.Clock.utc_now()
    attempt = job_attempt(changeset.context)

    case subscription(storage, delivery.subscription_id) do
      %{state: :active} = subscription ->
        if DateTime.compare(subscription.expires_at, now) == :gt do
          attempt(changeset, storage, subscription, delivery, now, attempt)
        else
          ended(changeset, attempt)
        end

      _gone_or_expired ->
        ended(changeset, attempt)
    end
  end

  defp ended(changeset, attempt) do
    changeset
    |> AshQueue.transition_to(:failed)
    |> record(attempt, nil, "subscription ended")
  end

  defp attempt(changeset, storage, subscription, delivery, now, attempt) do
    request = %{
      server_url: subscription.server_url,
      url: subscription.url,
      subscription_id: subscription.id,
      event_id: delivery.event_id,
      body: delivery.body,
      secrets: active_secrets(subscription, now)
    }

    case storage.sender.deliver(request, storage.sender_options) do
      {:ok, status} when status in 200..299 ->
        Logger.debug(
          "MCP Events subscription #{subscription.id}: delivered event #{delivery.event_id} (HTTP #{status}, attempt #{attempt})"
        )

        changeset |> AshQueue.transition_to(:delivered) |> record(attempt, status, nil)

      {:ok, 410} ->
        Logger.info("MCP Events subscription #{subscription.id}: callback returned 410, removing")

        Ash.destroy!(subscription,
          action: :unsubscribe,
          authorize?: false,
          domain: storage.domain
        )

        changeset |> AshQueue.transition_to(:failed) |> record(attempt, 410, "HTTP 410")

      {:ok, status} when status == 413 or (status in 400..499 and status not in [408, 429]) ->
        Logger.info(
          "MCP Events subscription #{subscription.id}: event #{delivery.event_id} rejected with #{status}, not retrying"
        )

        changeset
        |> AshQueue.transition_to(:failed)
        |> record(attempt, status, "HTTP #{status}")

      {:ok, status} ->
        Ash.Changeset.add_error(changeset, "HTTP #{status}")

      {:error, message} ->
        Ash.Changeset.add_error(changeset, message)
    end
  end

  @doc "The secrets an attempt is signed with: both during the rotation window, then the newest."
  def active_secrets(subscription, now) do
    case subscription.rotation_ends_at do
      %DateTime{} = ends_at ->
        if DateTime.compare(ends_at, now) == :gt,
          do: subscription.secrets,
          else: Enum.take(subscription.secrets, 1)

      nil ->
        Enum.take(subscription.secrets, 1)
    end
  end

  defp record(changeset, attempt, status, error) do
    changeset
    |> Ash.Changeset.force_change_attribute(:attempt, attempt)
    |> Ash.Changeset.force_change_attribute(:last_status, status)
    |> Ash.Changeset.force_change_attribute(:last_error, error)
  end

  defp subscription(storage, id) do
    case Ash.get(storage.subscription, id,
           authorize?: false,
           domain: storage.domain,
           error?: false
         ) do
      {:ok, subscription} -> subscription
      _ -> nil
    end
  end

  defp job_attempt(%{ash_queue: %{job: %{attempt: attempt}}}) when is_integer(attempt),
    do: attempt

  defp job_attempt(_context), do: 1
end
