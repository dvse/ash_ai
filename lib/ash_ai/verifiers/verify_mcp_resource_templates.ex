# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Verifiers.VerifyMcpResourceTemplates do
  @moduledoc """
  Verifies `mcp_resource_template` entities (BLENDED-022).

  The URI template is RFC 6570 level 1 with at least one variable; every variable is a public
  attribute of the resource and an argument of the action; the action is a generic action
  returning a string or a binary; `list` (or the primary read) is a read action; and the `row_*`
  options name public attributes.
  """
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> AshAi.Info.mcp_resource_templates()
    |> Enum.find_value(:ok, fn template ->
      case problem(template) do
        nil ->
          nil

        message ->
          {:error,
           Spark.Error.DslError.exception(
             message: "mcp_resource_template #{inspect(template.name)} #{message}",
             path: [:mcp_resources, :mcp_resource_template, template.name],
             module: module
           )}
      end
    end)
  end

  defp problem(template) do
    resource = template.resource

    with {:ok, variables} <- template_variables(template.uri_template),
         nil <- action_problem(resource, template.action, variables),
         nil <- list_problem(resource, template.list) do
      Enum.find_value(
        Enum.map(variables, &{"variable {#{&1}}", &1}) ++
          for(
            option <- [:row_name, :row_title, :row_description],
            field = Map.get(template, option),
            do: {"#{option} #{inspect(field)}", field}
          ),
        fn {what, field} ->
          case Ash.Resource.Info.public_attribute(resource, field) do
            nil -> "#{what} is not a public attribute of #{inspect(resource)}"
            _attribute -> nil
          end
        end
      )
    end
  end

  defp template_variables(uri_template) do
    case AshAi.McpResourceTemplate.variables(uri_template) do
      {:ok, variables} -> {:ok, variables}
      {:error, message} -> "uri template #{inspect(uri_template)} #{message}"
    end
  end

  defp action_problem(resource, action_name, variables) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{type: :action, returns: returns} = action
      when returns in [Ash.Type.String, Ash.Type.Binary] ->
        arguments = Enum.map(action.arguments, &to_string(&1.name))

        case Enum.reject(variables, &(&1 in arguments)) do
          [] ->
            nil

          [missing | _] ->
            "variable {#{missing}} is not an argument of action #{inspect(action_name)}"
        end

      %{type: :action} ->
        "action #{inspect(action_name)} must return :string or :binary"

      _ ->
        "action #{inspect(action_name)} is not a generic action of #{inspect(resource)}"
    end
  end

  defp list_problem(resource, nil) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      nil -> "has no list action and #{inspect(resource)} has no primary read action"
      _read -> nil
    end
  end

  defp list_problem(resource, list) do
    case Ash.Resource.Info.action(resource, list) do
      %{type: :read} -> nil
      _ -> "list #{inspect(list)} is not a read action of #{inspect(resource)}"
    end
  end
end
