# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpActions do
  # BLENDED-014: the MCP server as one public generic action, so a host that
  # exposes resource actions (a publication gateway) can publish an MCP
  # endpoint without a Plug pipeline. Mirrors `AshHyperlang.EvalActions`.
  @mcp_actions %Spark.Dsl.Section{
    name: :mcp_actions,
    describe: """
    Configures the MCP server behind the synthesized `:mcp` action.

    The options are the `AshAi.Mcp.Router` options that describe the server
    (which tools and resources it serves, and how). The request's actor,
    tenant and context are the action's own.
    """,
    examples: [
      """
      mcp_actions do
        otp_app :my_app
        tools [:list_posts, :create_post]
      end
      """
    ],
    schema: [
      mcp_action_name: [
        type: :atom,
        default: :mcp,
        doc: "Name of the synthesized MCP action. Defaults to `:mcp`."
      ],
      otp_app: [
        type: :atom,
        doc:
          "OTP app whose `:ash_domains` provide the tools. Defaults to the resource's domain's `:otp_app`."
      ],
      tools: [
        type: {:or, [:boolean, {:wrap_list, :atom}]},
        doc: "Tool names to serve (the router's `tools` option). Defaults to every tool."
      ],
      actions: [
        type:
          {:wrap_list,
           {:tuple, [{:spark, Ash.Resource}, {:or, [{:list, :atom}, {:literal, :*}]}]}},
        doc:
          "`{Resource, [:action]}` or `{Resource, :*}` filters (the router's `actions` option)."
      ],
      mcp_resources: [
        type: {:or, [{:wrap_list, :atom}, {:literal, :*}]},
        doc: "MCP resource names to serve, or `:*` (the router's `mcp_resources` option)."
      ],
      exclude_actions: [
        type: {:wrap_list, {:tuple, [{:spark, Ash.Resource}, :atom]}},
        doc: "`{Resource, :action}` pairs to leave out (the router's `exclude_actions` option)."
      ],
      forbidden_fields: [
        type: {:in, [:hide, :display]},
        doc:
          "How field-policy-forbidden fields render (BLENDED-012). Defaults to each tool's `tools` section setting."
      ],
      strict: [
        type: :boolean,
        doc: "OpenAI strict-mode input schemas. Defaults to `false`, as the router does."
      ],
      mcp_name: [type: :string, doc: "The server name in `serverInfo`."],
      mcp_server_version: [type: :string, doc: "The server version in `serverInfo`."],
      instructions: [type: :string, doc: "Server instructions sent to the client."],
      protocol_version_statement: [
        type: :string,
        doc: "The protocol version the `initialize` response states."
      ],
      list_ttl_ms: [type: :non_neg_integer, doc: "`ttlMs` of 2026-07-28 list results."],
      read_ttl_ms: [type: :non_neg_integer, doc: "`ttlMs` of 2026-07-28 read results."],
      cache_scope: [type: :string, doc: "`cacheScope` of 2026-07-28 cacheable results."],
      resource_metadata_url: [
        type: :string,
        doc:
          "OAuth protected-resource metadata URL named in `mcp/www_authenticate` (BLENDED-013)."
      ],
      security_schemes: [
        type: {:list, :map},
        doc:
          "Default `securitySchemes` of every tool that declares none (BLENDED-016; the router's `security_schemes` option)."
      ]
    ],
    entities: []
  }

  @moduledoc """
  Resource extension that synthesizes a public generic `:mcp` action serving
  the Model Context Protocol (BLENDED-014).

  ```elixir
  defmodule MyApp.Mcp do
    use Ash.Resource, domain: MyApp.Domain, extensions: [AshAi.McpActions]

    mcp_actions do
      otp_app :my_app
      tools [:list_posts, :create_post]
    end
  end
  ```

  The action takes one `request` map describing an HTTP `POST` to the MCP
  endpoint and returns the response `AshAi.Mcp.Server.handle_post/4` would
  have sent:

    * `request.body` — the JSON-RPC message (decoded JSON, or the raw text);
    * `request.headers` — the request headers, lower-case names, each a
      string or a list of strings (`mcp-session-id`, `mcp-protocol-version`,
      `mcp-method`, `mcp-name`, ...);
    * `request.server_url` — optional, the endpoint's public URL.

  The result is `%{status: integer, headers: %{name => value}, body: string}`.

  The request runs with the action's actor, tenant and context, so tools see
  the caller who invoked the action, and `tools/list` is filtered for that
  caller. The host owns HTTP: routing, the `Origin` check
  (`AshAi.Mcp.Server.check_origin/2`), `GET` (405) and `DELETE`.
  """

  use Spark.Dsl.Extension,
    sections: [@mcp_actions],
    transformers: [AshAi.McpActions.Transformers.AddActions]
end
