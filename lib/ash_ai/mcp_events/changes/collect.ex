# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Changes.Collect do
  @moduledoc """
  The body of a subscription's `collect` edge (BLENDED-026, design §5), run as the subscriber:

    1. read the next occurrences of its event after `cursor` (up to 64, by `sort_key`);
    2. keep those whose facts satisfy its arguments (`AshAi.McpEvents.Catalog.matches?/2`);
    3. read each record through the resource's primary read as the subscriber, with
       `authorize?: true` and its field policies: a record the subscriber cannot read, or one
       whose payload field a policy hides, is not delivered at all (not even its existence);
    4. write one delivery row per match with the frozen body (a body over 256 KiB is logged and
       not written);
    5. advance `cursor` to the last occurrence read.

  A subscription past its `expires_at` (by `AshAi.McpEvents.Clock`), or whose subscriber can no
  longer be looked up, advances its cursor and delivers nothing.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias AshAi.McpEvents
  alias AshAi.McpEvents.{ActorPersister, Catalog}

  @impl true
  def change(changeset, _opts, _context) do
    subscription = changeset.data
    storage = Catalog.storage_for_resource!(changeset.resource)

    case next_occurrences(storage, subscription) do
      [] ->
        changeset

      occurrences ->
        deliveries = deliveries(storage, subscription, occurrences)
        cursor = List.last(occurrences).sort_key

        changeset
        |> Ash.Changeset.force_change_attribute(:cursor, cursor)
        |> Ash.Changeset.after_action(fn _changeset, result ->
          write_deliveries(storage, deliveries, result)
        end)
    end
  end

  defp next_occurrences(storage, subscription) do
    name = subscription.name
    cursor = subscription.cursor

    storage.occurrence
    |> Ash.Query.filter(name == ^name and sort_key > ^cursor)
    |> Ash.Query.sort(sort_key: :asc)
    |> Ash.Query.limit(McpEvents.collect_batch())
    |> Ash.read!(authorize?: false, domain: storage.domain)
  end

  defp deliveries(storage, subscription, occurrences) do
    now = McpEvents.Clock.utc_now()
    event = Catalog.event(storage.domain, subscription.name)

    with true <- DateTime.compare(subscription.expires_at, now) == :gt,
         true <- not is_nil(event),
         {:ok, actor} <- subscriber(storage, subscription) do
      occurrences
      |> Enum.filter(&Catalog.matches?(subscription.arguments, &1.facts))
      |> Enum.flat_map(&delivery(storage, subscription, event, actor, &1))
    else
      _ -> []
    end
  end

  defp subscriber(storage, subscription) do
    persister = ActorPersister.for_storage(storage)

    case persister.lookup(subscription.requester || %{}) do
      {:ok, actor} ->
        {:ok, actor}

      {:error, error} ->
        Logger.warning(
          "MCP Events subscription #{subscription.id}: its subscriber could not be looked up (#{inspect(error)}); nothing delivered"
        )

        :error
    end
  end

  defp delivery(_storage, subscription, event, actor, occurrence) do
    with {:ok, record} <- read_as(event, actor, occurrence),
         {:ok, data} <- Catalog.payload(event, record),
         {:ok, body} <- body(occurrence, data) do
      [
        %{
          id: McpEvents.delivery_id(subscription.id, occurrence.id),
          subscription_id: subscription.id,
          event_id: occurrence.id,
          name: occurrence.name,
          body: body
        }
      ]
    else
      _ -> []
    end
  end

  defp read_as(event, actor, occurrence) do
    key =
      Map.new(occurrence.key, fn {field, value} -> {String.to_existing_atom(field), value} end)

    case Ash.get(event.resource, key, actor: actor, authorize?: true, domain: nil) do
      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        if not_readable?(error) do
          :skip
        else
          raise Ash.Error.to_error_class(error)
        end
    end
  end

  defp not_readable?(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.all?(fn
      %Ash.Error.Query.NotFound{} -> true
      %Ash.Error.Forbidden.Policy{} -> true
      %Ash.Error.Forbidden.ForbiddenField{} -> true
      %Ash.Error.Forbidden{} -> true
      _ -> false
    end)
  end

  defp body(occurrence, data) do
    body =
      Jason.OrderedObject.new([
        {"eventId", occurrence.id},
        {"name", occurrence.name},
        {"timestamp", McpEvents.iso8601(occurrence.occurred_at)},
        {"data", data},
        {"cursor", nil}
      ])
      |> Jason.encode!()

    if byte_size(body) > McpEvents.max_event_bytes() do
      Logger.error("MCP Events event #{occurrence.id} exceeds 256 KiB; not delivered")
      :too_large
    else
      {:ok, body}
    end
  end

  defp write_deliveries(storage, deliveries, result) do
    Enum.reduce_while(deliveries, {:ok, result, []}, fn input, {:ok, result, notifications} ->
      case Ash.get(storage.delivery, input.id,
             authorize?: false,
             domain: storage.domain,
             error?: false
           ) do
        {:ok, %{}} ->
          {:cont, {:ok, result, notifications}}

        _absent ->
          storage.delivery
          |> Ash.Changeset.for_create(:enqueue, input, authorize?: false, domain: storage.domain)
          |> Ash.create(return_notifications?: true)
          |> case do
            {:ok, _delivery, new} -> {:cont, {:ok, result, notifications ++ new}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end
end
