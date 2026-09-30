# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpActions.Transformers.AddActions do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshAi.McpActions.Info

  def transform(dsl_state) do
    add_mcp_action(dsl_state, Info.mcp_action_name(dsl_state))
  end

  def after?(_), do: true

  defp add_mcp_action(dsl_state, name) do
    {:ok, request_arg} =
      Builder.build_action_argument(:request, :map,
        allow_nil?: false,
        description:
          "An HTTP POST to the MCP endpoint: `body` (the JSON-RPC message), `headers` (lower-case names; a string or a list of strings each) and optional `server_url`."
      )

    Builder.add_new_action(dsl_state, :action, name,
      public?: true,
      returns: :map,
      constraints: [
        fields: [
          status: [type: :integer, allow_nil?: false],
          headers: [type: :map, allow_nil?: false],
          body: [
            type: :string,
            allow_nil?: false,
            constraints: [allow_empty?: true, trim?: false]
          ]
        ]
      ],
      arguments: [request_arg],
      run: AshAi.McpActions.Run.Mcp
    )
  end
end
