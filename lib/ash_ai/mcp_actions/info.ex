# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpActions.Info do
  @moduledoc "Introspection helpers for the `AshAi.McpActions` extension (BLENDED-014)."

  alias Spark.Dsl.Extension

  @server_options [
    :tools,
    :actions,
    :mcp_resources,
    :exclude_actions,
    :forbidden_fields,
    :strict,
    :mcp_name,
    :mcp_server_version,
    :instructions,
    :protocol_version_statement,
    :list_ttl_ms,
    :read_ttl_ms,
    :cache_scope,
    :resource_metadata_url,
    :security_schemes,
    :events
  ]

  @doc "Name of the synthesized MCP action. Defaults to `:mcp`."
  @spec mcp_action_name(Ash.Resource.t() | Spark.Dsl.t()) :: atom()
  def mcp_action_name(resource),
    do: Extension.get_opt(resource, [:mcp_actions], :mcp_action_name, :mcp)

  @doc """
  OTP app whose domains provide the tools. Falls back to the resource's
  domain's `:otp_app` when not explicitly configured.
  """
  @spec otp_app(Ash.Resource.t()) :: atom() | nil
  def otp_app(resource) do
    Extension.get_opt(resource, [:mcp_actions], :otp_app, nil) ||
      Spark.otp_app(Ash.Resource.Info.domain(resource))
  end

  @doc "The `AshAi.Mcp.Server` options the section sets, `otp_app` included."
  @spec server_options(Ash.Resource.t()) :: keyword()
  def server_options(resource) do
    configured =
      for key <- @server_options,
          value = Extension.get_opt(resource, [:mcp_actions], key, nil),
          not is_nil(value),
          do: {key, value}

    [otp_app: otp_app(resource)] ++ configured
  end
end
