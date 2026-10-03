# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      # BLENDED-023: the elicitation state of initialize-based MCP connections.
      AshAi.Mcp.Elicitations.child_specs(),
      strategy: :one_for_one,
      name: AshAi.Supervisor
    )
  end
end
