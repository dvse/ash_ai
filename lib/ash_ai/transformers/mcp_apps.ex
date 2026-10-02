# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Transformers.McpApps do
  @moduledoc false
  use Spark.Dsl.Transformer

  def after?(_), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    ui_resources = Spark.Dsl.Transformer.get_entities(dsl_state, [:mcp_resources])

    with :ok <- verify_view_sources(ui_resources) do
      link_tools(dsl_state, ui_resources)
    end
  end

  # BLENDED-020: a view is an HTML file or a page, never both or neither.
  defp verify_view_sources(ui_resources) do
    ui_resources
    |> Enum.filter(&match?(%AshAi.McpUiResource{}, &1))
    |> Enum.find_value(:ok, fn resource ->
      case {resource.html_path, resource.page} do
        {nil, nil} ->
          view_source_error(resource, "needs `html_path` or `page`")

        {path, page} when is_binary(path) and not is_nil(page) ->
          view_source_error(resource, "takes `html_path` or `page`, not both")

        _one ->
          nil
      end
    end)
  end

  defp view_source_error(resource, message) do
    {:error,
     Spark.Error.DslError.exception(
       path: [:mcp_resources, :mcp_ui_resource, resource.name],
       message: "mcp_ui_resource `#{resource.name}` #{message}"
     )}
  end

  defp link_tools(dsl_state, ui_resources) do
    dsl_state
    |> AshAi.Info.action_tools()
    |> Enum.filter(& &1.ui)
    |> Enum.reduce({:ok, dsl_state}, fn tool, {:ok, dsl} ->
      with {:ok, uri} <- resolve_ui(tool.ui, ui_resources, tool.name) do
        updated_meta =
          (tool._meta || %{})
          |> Map.update("ui", %{"resourceUri" => uri}, &Map.put(&1, "resourceUri", uri))

        {:ok,
         Spark.Dsl.Transformer.replace_entity(
           dsl,
           [:tools],
           %{tool | _meta: updated_meta, ui: nil},
           &(&1.name == tool.name)
         )}
      end
    end)
  end

  defp resolve_ui(uri, _ui_resources, _tool_name) when is_binary(uri), do: {:ok, uri}

  defp resolve_ui(name, ui_resources, tool_name) when is_atom(name) do
    case Enum.find(ui_resources, &(&1.name == name)) do
      %{uri: uri} ->
        {:ok, uri}

      nil ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:tools, tool_name],
           message:
             "tool `#{tool_name}` references ui resource `#{name}`, but no `mcp_ui_resource` with that name was found"
         )}
    end
  end
end
