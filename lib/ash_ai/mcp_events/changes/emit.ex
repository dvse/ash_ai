# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Changes.Emit do
  @moduledoc """
  Emission in the writer's transaction (BLENDED-026). `AshAi.McpEvents.Transformers.AddEmit`
  adds this change to every create and update action of a resource that may emit (and to its
  destroy actions when an event names one).

  After the action, inside its transaction, it writes one occurrence row per event that fired:

    * a `states` event fires when the space attribute moved into one of its states (a create
      counts as a move from nothing), whichever action wrote it: commanded edges, injected
      edges, exhaustion transitions and plain updates alike;
    * an `action` event fires when its action succeeded.

  Nothing after the commit is relied on: a crash after the commit loses nothing, and the
  subscriptions' `collect` edges find the rows by sweep.
  """

  use Ash.Resource.Change

  alias AshAi.McpEvents
  alias AshAi.McpEvent, as: Event
  alias AshAi.McpEvents.Catalog

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &emit/2)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @doc false
  def emit(changeset, result) do
    domain = changeset.domain || Ash.Resource.Info.domain(changeset.resource)

    case Catalog.storage(domain) do
      nil ->
        {:ok, result}

      storage ->
        fired =
          storage
          |> Catalog.events_of()
          |> Enum.filter(&(&1.resource == changeset.resource and fired?(&1, changeset, result)))

        write(fired, storage, changeset, result)
    end
  end

  defp fired?(%Event{} = event, changeset, result) do
    case Event.source(event) do
      :states ->
        before =
          if changeset.action_type == :create,
            do: nil,
            else: Map.get(changeset.data, event.attribute)

        now = Map.get(result, event.attribute)
        now in event.states and now != before

      :action ->
        changeset.action.name == event.action

      _ ->
        false
    end
  end

  defp write([], _storage, _changeset, result), do: {:ok, result}

  defp write(events, storage, changeset, result) do
    occurred_at = AshAi.McpEvents.Clock.utc_now()

    Enum.reduce_while(events, {:ok, result, []}, fn event, {:ok, result, notifications} ->
      id = McpEvents.event_id(occurred_at)

      input = %{
        id: id,
        name: event.name,
        resource: inspect(changeset.resource),
        key: Catalog.key(changeset.resource, result),
        facts: Catalog.facts(event, result),
        occurred_at: occurred_at,
        sort_key: McpEvents.sort_key(occurred_at, id),
        prune_at: McpEvents.add_ms(occurred_at, McpEvents.prune_after_ms())
      }

      storage.occurrence
      |> Ash.Changeset.for_create(:emit, input,
        authorize?: false,
        domain: storage.domain,
        tenant: changeset.tenant
      )
      |> Ash.create(return_notifications?: true)
      |> case do
        {:ok, _occurrence, new_notifications} ->
          {:cont, {:ok, result, notifications ++ new_notifications}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end
end
