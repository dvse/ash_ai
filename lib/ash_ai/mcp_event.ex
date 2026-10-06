# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvent do
  @moduledoc """
  An MCP event (BLENDED-026): an `event` declared in a resource's `mcp_events` section, or one
  generated for a terminal state of an AshQueue space (`default?: true`).

  Exactly one source: `states` (the space attribute moved into one of them), `action` (that
  create, update or destroy action ran), or `becomes_current?` (a temporal version became
  current; refused, as Ash has no temporal resources).
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          states: [atom()] | nil,
          space: atom() | nil,
          action: atom() | nil,
          becomes_current?: boolean(),
          filter: [atom()],
          payload: [atom()] | nil,
          resource: module() | nil,
          attribute: atom() | nil,
          default?: boolean()
        }

  defstruct [
    :name,
    :description,
    :states,
    :space,
    :action,
    :payload,
    :resource,
    :attribute,
    :__identifier__,
    :__spark_metadata__,
    becomes_current?: false,
    filter: [],
    default?: false
  ]

  @doc "The source kind: `:states`, `:action` or `:becomes_current`."
  def source(%__MODULE__{states: [_ | _]}), do: :states
  def source(%__MODULE__{action: action}) when not is_nil(action), do: :action
  def source(%__MODULE__{becomes_current?: true}), do: :becomes_current
  def source(%__MODULE__{}), do: nil
end
