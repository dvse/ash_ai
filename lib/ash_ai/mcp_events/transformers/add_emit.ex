# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Transformers.AddEmit do
  @moduledoc """
  BLENDED-026: adds `AshAi.McpEvents.Changes.Emit` as a global change (Ash's own mechanism, as
  AshQueue's `BuildSpace` injects `GuardedTransition`) to the create and update actions of every
  resource that may emit an event: one that declares an `event`, or one with an AshQueue space
  (whose terminal states are default events when its domain names event storage). Destroy
  actions get it too when an event names one. Whether an action actually fires is decided at run
  time from the domain's catalog, so a resource whose domain names no storage writes nothing.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(Ash.Resource.Transformers.ValidationsAndChangesForType), do: true
  def before?(_), do: false

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    if resource?(dsl_state) do
      add_change(dsl_state)
    else
      {:ok, dsl_state}
    end
  end

  defp resource?(dsl_state), do: Map.has_key?(dsl_state, [:attributes])

  defp add_change(dsl_state) do
    events = Transformer.get_entities(dsl_state, [:mcp_events])
    spaces? = Enum.any?(Transformer.get_entities(dsl_state, [:queue]) || [], &space?/1)

    if events == [] and not spaces? do
      {:ok, dsl_state}
    else
      destroy? =
        Enum.any?(events, fn event ->
          case event.action && Ash.Resource.Info.action(dsl_state, event.action) do
            %{type: :destroy} -> true
            _ -> false
          end
        end)

      on = if destroy?, do: [:create, :update, :destroy], else: [:create, :update]
      Ash.Resource.Builder.add_change(dsl_state, AshAi.McpEvents.Changes.Emit, on: on)
    end
  end

  defp space?(%{__struct__: AshQueue.Resource.Space}), do: true
  defp space?(_entity), do: false
end
