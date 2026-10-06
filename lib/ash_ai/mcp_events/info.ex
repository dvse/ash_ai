# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Info do
  @moduledoc "Introspection of the `mcp_events` section (BLENDED-026)."

  use Spark.InfoGenerator, extension: AshAi, sections: [:mcp_events]

  @doc "The declared `event` entities of a resource."
  @spec declared_events(module() | map()) :: [AshAi.McpEvent.t()]
  def declared_events(dsl_or_module), do: mcp_events(dsl_or_module)

  @doc "True when the domain names its event storage."
  @spec storage?(module() | map()) :: boolean()
  def storage?(dsl_or_module) do
    not is_nil(Spark.Dsl.Extension.get_opt(dsl_or_module, [:mcp_events], :subscription, nil))
  end
end
