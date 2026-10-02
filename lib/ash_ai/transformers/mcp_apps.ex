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

    with :ok <- verify_sources(ui_resources),
         :ok <- verify_presentation_tools(dsl_state, ui_resources) do
      resolve_tool_uis(dsl_state, ui_resources)
    end
  end

  # BLENDED-020: a UI resource is served from exactly one source.
  defp verify_sources(ui_resources) do
    ui_resources
    |> Enum.filter(&match?(%AshAi.McpUiResource{}, &1))
    |> Enum.find_value(:ok, fn
      %{html_path: nil, page: nil, name: name} ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:mcp_resources, name],
           message:
             "mcp_ui_resource `#{name}` needs `html_path` (a static file) or `page` (an `AshAi.McpUiPage` module)"
         )}

      %{html_path: path, page: page, name: name} when not is_nil(path) and not is_nil(page) ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:mcp_resources, name],
           message:
             "mcp_ui_resource `#{name}` sets both `html_path` and `page`; a view is served from one of them"
         )}

      _resource ->
        nil
    end)
  end

  # BLENDED-020: a page-backed resource's app-only `<name>_presentation` tool must not shadow a
  # declared tool.
  defp verify_presentation_tools(dsl_state, ui_resources) do
    declared =
      MapSet.new(
        Enum.map(AshAi.Info.action_tools(dsl_state), &to_string(&1.name)) ++
          Enum.flat_map(AshAi.Info.exposes(dsl_state), fn expose ->
            Enum.map(expose.interfaces, &to_string(&1.name))
          end)
      )

    ui_resources
    |> Enum.filter(&AshAi.McpUiPage.page?/1)
    |> Enum.find_value(:ok, fn resource ->
      name = AshAi.McpUiPage.presentation_tool(resource)

      if MapSet.member?(declared, name) do
        {:error,
         Spark.Error.DslError.exception(
           path: [:mcp_resources, resource.name],
           message:
             "mcp_ui_resource `#{resource.name}` serves its page through the app-only tool `#{name}`, which a declared tool already names"
         )}
      end
    end)
  end

  defp resolve_tool_uis(dsl_state, ui_resources) do
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
