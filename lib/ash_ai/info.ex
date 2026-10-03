# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Info do
  @moduledoc "Introspection functions for the `AshAi` extension."
  use Spark.InfoGenerator, extension: AshAi, sections: [:tools, :vectorize, :mcp_resources]

  @doc """
  Returns only `%AshAi.McpUiResource{}` entities from the `:mcp_resources` section.

  Spark's auto-generated `mcp_resources/1` returns all entities in the section
  (both `mcp_resource` and `mcp_ui_resource`). This function filters to UI resources only.
  """
  @spec mcp_ui_resources(module | map) :: [AshAi.McpUiResource.t()]
  def mcp_ui_resources(dsl_or_extended) do
    dsl_or_extended
    |> mcp_resources()
    |> Enum.filter(&match?(%AshAi.McpUiResource{}, &1))
  end

  @doc """
  Returns only `%AshAi.McpResource{}` entities (action-based) from the `:mcp_resources` section.
  """
  @spec mcp_action_resources(module | map) :: [AshAi.McpResource.t()]
  def mcp_action_resources(dsl_or_extended) do
    dsl_or_extended
    |> mcp_resources()
    |> Enum.filter(&match?(%AshAi.McpResource{}, &1))
  end

  @doc """
  Returns only `%AshAi.McpResourceTemplate{}` entities (row-backed, BLENDED-022) from the
  `:mcp_resources` section.
  """
  @spec mcp_resource_templates(module | map) :: [AshAi.McpResourceTemplate.t()]
  def mcp_resource_templates(dsl_or_extended) do
    dsl_or_extended
    |> mcp_resources()
    |> Enum.filter(&match?(%AshAi.McpResourceTemplate{}, &1))
  end

  @doc """
  Returns only `%AshAi.Tool{}` entities from the `:tools` section.

  Spark's auto-generated `tools/1` returns every entity in the section, including
  `%AshAi.Expose{}` entries.
  """
  @spec action_tools(module | map) :: [AshAi.Tool.t()]
  def action_tools(dsl_or_extended) do
    dsl_or_extended
    |> tools()
    |> Enum.filter(&match?(%AshAi.Tool{}, &1))
  end

  @doc "Returns the `%AshAi.Expose{}` entities from a domain's `:tools` section."
  @spec exposes(module | map) :: [AshAi.Expose.t()]
  def exposes(dsl_or_extended) do
    dsl_or_extended
    |> tools()
    |> Enum.filter(&match?(%AshAi.Expose{}, &1))
  end

  @doc """
  Builds one `%AshAi.Tool{}` per exposed `interface` of a domain.

  The tool is named after the interface and calls the action behind the matching domain
  `define`. Interfaces over non-public actions are skipped. A read `define` with `get_by`
  or `get_by_identity` becomes a single-record (`get_by`) tool, and an update/destroy
  `define` with `get_by_identity` addresses records by that identity.
  """
  # BLENDED-001: from ash_hyperlang lib/ash_hyperlang/domain.ex:361 (`declared_actions/1`)
  @spec interface_tools(module) :: [AshAi.Tool.t()]
  def interface_tools(domain) do
    references_by_resource =
      domain
      |> Ash.Domain.Info.resource_references()
      |> Map.new(&{&1.resource, &1})

    domain
    |> exposes()
    |> Enum.flat_map(fn %AshAi.Expose{resource: resource} = expose ->
      # `AshAi.Verifiers.VerifyExposures` guarantees the reference and every define exist.
      interfaces_by_name =
        references_by_resource
        |> Map.fetch!(resource)
        |> Map.get(:definitions)
        |> Enum.filter(&match?(%Ash.Resource.Interface{}, &1))
        |> Map.new(&{&1.name, &1})

      Enum.flat_map(expose.interfaces, fn exposed ->
        interface = Map.fetch!(interfaces_by_name, exposed.name)
        action = Ash.Resource.Info.action(resource, interface.action || interface.name)

        # BLENDED-002: from ash_hyperlang lib/ash_hyperlang/domain.ex:417 (`public_action?/2`)
        if action.public? do
          [interface_tool(resource, action, interface, exposed)]
        else
          []
        end
      end)
    end)
  end

  defp interface_tool(resource, action, interface, exposed) do
    %AshAi.Tool{
      name: exposed.name,
      resource: resource,
      action: action.name,
      interface: exposed.name,
      description: exposed.description,
      example: exposed.example,
      refine?: exposed.refine?,
      blocking?: exposed.blocking?,
      continuation_target?: exposed.continuation_target?,
      hints: exposed.hints,
      annotations: exposed.annotations,
      output_schema?: exposed.output_schema?,
      security_schemes: exposed.security_schemes,
      file_params: exposed.file_params,
      load: [],
      async: true,
      arguments: [],
      _meta: %{}
    }
    |> interface_lookup(resource, action, interface)
  end

  # BLENDED-001: from ash_hyperlang lib/ash_hyperlang/surface.ex:277 (`interface_arguments/3`)
  defp interface_lookup(tool, resource, %{type: :read}, %{get_by_identity: identity})
       when not is_nil(identity) do
    %{tool | get_by: Ash.Resource.Info.identity(resource, identity).keys}
  end

  defp interface_lookup(tool, _resource, %{type: :read}, %{get_by: get_by})
       when not is_nil(get_by) do
    %{tool | get_by: get_by}
  end

  defp interface_lookup(tool, _resource, %{type: type}, %{get_by_identity: identity})
       when type in [:update, :destroy] and not is_nil(identity) do
    %{tool | identity: identity}
  end

  defp interface_lookup(tool, _resource, _action, _interface), do: tool
end
