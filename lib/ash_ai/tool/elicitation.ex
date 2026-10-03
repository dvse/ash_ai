# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Tool.Elicitation do
  @moduledoc """
  Missing input of an MCP tool call, asked of the user as a form (BLENDED-023).

  A tool declared with `elicit_missing?: true` builds its action's input first, without running
  it (`AshAi.Tool.Execution.input_errors/3`). When every error is a missing or invalid value of
  an input the tool's schema declares (`Ash.Error.Changes.Required`, `Ash.Error.Query.Required`,
  `Ash.Error.Changes.InvalidArgument`, `Ash.Error.Query.InvalidArgument`,
  `Ash.Error.Action.InvalidArgument`), the server answers with a form elicitation request whose
  `requestedSchema` describes exactly those inputs, instead of running the action. The client
  calls the tool again with the answers; the call is validated again and, once valid, the action
  runs once, as any call does. Nothing is kept between the two calls.

  The request is the MCP form elicitation `elicitation/create` (MCP 2025-06-18 and 2025-11-25
  `ElicitRequestFormParams`, 2026-07-28 embedded in an `InputRequiredResult`), or
  `openai/elicitation/create` when the client advertises the `openai/elicitation` extension's
  `form` (mcp-extensions `docs/spec.md`, "OpenAI Form Elicitation").
  """

  alias AshAi.Tool
  alias AshAi.Tool.Execution

  @input_key "missing_input"

  @elicitable [
    Ash.Error.Changes.Required,
    Ash.Error.Query.Required,
    Ash.Error.Changes.InvalidArgument,
    Ash.Error.Query.InvalidArgument,
    Ash.Error.Action.InvalidArgument
  ]

  # MCP `StringSchema.format`
  @string_formats ["email", "uri", "date", "date-time"]

  @doc "The key of the input request in `inputRequests` and of its answer in `inputResponses`."
  def input_key, do: @input_key

  @doc """
  The form dialect a client's capabilities admit: `:openai` when it advertises
  `extensions["openai/elicitation"].form`, `:standard` when it declares `elicitation` with form
  support (`form`, or an empty object, which means form), `nil` otherwise. Values that are not
  objects admit nothing.
  """
  def dialect(%{"extensions" => %{"openai/elicitation" => %{"form" => %{}}}}), do: :openai

  def dialect(%{"elicitation" => %{"form" => %{}}}), do: :standard
  def dialect(%{"elicitation" => elicitation}) when elicitation == %{}, do: :standard
  def dialect(_capabilities), do: nil

  @doc "The method of a form request in `dialect`."
  def method(:openai), do: "openai/elicitation/create"
  def method(:standard), do: "elicitation/create"

  @doc """
  The answer to the tool's input request in a call's `inputResponses`: `{:accept, content}`,
  `:decline`, `:cancel`, or `nil` when there is none (or it is not an elicitation result).
  """
  def answer(%{@input_key => %{"action" => "accept"} = result}) do
    case result["content"] do
      content when is_map(content) -> {:accept, content}
      nil -> {:accept, %{}}
      _other -> nil
    end
  end

  def answer(%{@input_key => %{"action" => "decline"}}), do: :decline
  def answer(%{@input_key => %{"action" => "cancel"}}), do: :cancel
  def answer(_input_responses), do: nil

  @doc """
  The call's arguments with an accepted answer's values put into the action input (`input`),
  over the values the call carries.
  """
  def merge(arguments, content) when map_size(content) == 0, do: arguments

  def merge(arguments, content) do
    input =
      case arguments["input"] do
        input when is_map(input) -> input
        _other -> %{}
      end

    Map.put(arguments, "input", Map.merge(input, content))
  end

  @doc """
  The tool error a declined or cancelled answer is: the action did not run.
  """
  def refusal_text(%Tool{name: name}, :decline), do: "input declined: tool #{name} did not run"
  def refusal_text(%Tool{name: name}, :cancel), do: "input cancelled: tool #{name} did not run"

  @doc """
  Decides a call of `tool` with `arguments` (after argument transformation): `:run`, or
  `{:input_required, request}` with the form request (`method` and `params`) asking for the
  missing inputs in `dialect`. `answered` is the content of the answer that was merged into the
  arguments (`%{}` when none): its fields are asked again with their answers as defaults, so a
  form that comes back with one value still invalid keeps the others.
  """
  def decide(%Tool{elicit_missing?: true} = tool, arguments, context, dialect, answered)
      when dialect in [:openai, :standard] do
    with {:ok, [_ | _] = errors} <- Execution.input_errors(tool, arguments, context),
         {:ok, fields} <- elicitable_fields(tool, errors),
         {:ok, schema} <- requested_schema(tool, fields, missing(errors), answered, dialect) do
      {:input_required,
       %{
         "method" => method(dialect),
         "params" => %{
           "mode" => "form",
           "message" => message(tool, errors),
           "requestedSchema" => schema
         }
       }}
    else
      _ -> :run
    end
  end

  def decide(_tool, _arguments, _context, _dialect, _answered), do: :run

  # Every error is a missing or invalid value of an input the tool's schema declares.
  defp elicitable_fields(%Tool{resource: resource, action: action} = tool, errors) do
    inputs = declared_inputs(tool)

    errors
    |> Enum.reduce_while([], fn error, fields ->
      field = Map.get(error, :field)

      # An array item's error carries the item's index as its path.
      if error.__struct__ in @elicitable and Enum.all?(Map.get(error, :path, []), &is_integer/1) and
           is_atom(field) and Map.has_key?(inputs, field) do
        {:cont, [field | fields]}
      else
        {:halt, :error}
      end
    end)
    |> case do
      :error ->
        :error

      fields ->
        {:ok,
         fields
         |> Enum.reverse()
         |> Enum.uniq()
         |> Enum.map(&{&1, Map.fetch!(inputs, &1)})
         |> then(&{resource, action, &1})}
    end
  end

  # The action inputs the tool's input schema declares: its public arguments and accepted
  # attributes, less the file fields (BLENDED-018), which are not form values.
  defp declared_inputs(%Tool{resource: resource, action: action} = tool) do
    files = Enum.map(AshAi.Tool.OpenAi.file_params(tool), &elem(&1, 0))

    resource
    |> Ash.Resource.Info.action_inputs(action.name)
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&(&1 in files))
    |> Enum.flat_map(fn name ->
      case Enum.find(action.arguments, &(&1.name == name)) do
        %{public?: true} = argument ->
          [{name, argument}]

        %{} ->
          []

        nil ->
          case Ash.Resource.Info.attribute(resource, name) do
            nil -> []
            attribute -> [{name, attribute}]
          end
      end
    end)
    |> Map.new()
  end

  # The fields a `Required` error names: required in the form even when the field itself allows
  # nil (a create's `require_attributes`).
  defp missing(errors) do
    for %struct{field: field} <- errors,
        struct in [Ash.Error.Changes.Required, Ash.Error.Query.Required],
        do: field
  end

  @doc false
  # The form schema of `fields` (`{resource, action, [{name, argument_or_attribute}]}`), with the
  # answered fields too. `:error` when one of them has no form representation.
  def requested_schema(tool, {resource, action, fields}, missing, answered, dialect) do
    inputs = declared_inputs(tool)

    answered_fields =
      answered
      |> Map.keys()
      |> Enum.flat_map(fn key ->
        case Enum.find(inputs, fn {name, _field} -> to_string(name) == key end) do
          nil -> []
          field -> [field]
        end
      end)

    fields = Enum.uniq_by(fields ++ answered_fields, &elem(&1, 0))

    Enum.reduce_while(fields, {:ok, %{}, []}, fn {name, field}, {:ok, properties, required} ->
      key = to_string(name)

      case property(field, resource, action, dialect) do
        {:ok, property} ->
          property = put_default(property, Map.get(answered, key))

          required =
            if field.allow_nil? and name not in missing, do: required, else: required ++ [key]

          {:cont, {:ok, Map.put(properties, key, property), required}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, properties, required} ->
        {:ok,
         %{"type" => "object", "properties" => properties}
         |> then(&if(required == [], do: &1, else: Map.put(&1, "required", required)))}

      :error ->
        :error
    end
  end

  # One field's MCP `PrimitiveSchemaDefinition`: `StringSchema`, `NumberSchema`, `BooleanSchema`,
  # `UntitledSingleSelectEnumSchema` or `UntitledMultiSelectEnumSchema`. The type comes from
  # `AshAi.OpenApi` (the type the tool's input schema gives the field); constraints from the
  # field's own (`min`/`max` arrive as `minimum`/`maximum`; `min_length`/`max_length` become
  # `minLength`/`maxLength`, or `minItems`/`maxItems` on an array; `match` becomes `pattern` in
  # the OpenAI dialect, whose extended string schema admits it).
  defp property(field, resource, action, dialect) do
    {type, constraints} = resolved_type(field.type, field.constraints || [])

    field
    |> AshAi.OpenApi.resource_write_attribute_type(resource, action.type)
    |> primitive(type, constraints, dialect)
    |> case do
      {:ok, property} ->
        {:ok,
         property
         |> Map.put("title", title(field.name))
         |> put_present("description", Map.get(field, :description))}

      :error ->
        :error
    end
  end

  defp primitive(schema, type, constraints, dialect) do
    case {get(schema, :type), get(schema, :enum)} do
      {string, enum} when string in [:string, "string"] and is_list(enum) ->
        {:ok, %{"type" => "string", "enum" => Enum.map(enum, &to_string/1)}}

      {string, nil} when string in [:string, "string"] ->
        {:ok,
         %{"type" => "string"}
         |> put_format(get(schema, :format))
         |> put_present("minLength", constraints[:min_length])
         |> put_present("maxLength", constraints[:max_length])
         |> put_pattern(constraints[:match], dialect)}

      {number, _enum} when number in [:integer, "integer", :number, "number"] ->
        {:ok,
         %{"type" => to_string(number)}
         |> put_present("minimum", get(schema, :minimum))
         |> put_present("maximum", get(schema, :maximum))}

      {boolean, _enum} when boolean in [:boolean, "boolean"] ->
        {:ok, %{"type" => "boolean"}}

      {array, _enum} when array in [:array, "array"] and is_tuple(type) ->
        items = get(schema, :items)

        case {get(items, :type), get(items, :enum)} do
          {string, enum} when string in [:string, "string"] and is_list(enum) ->
            {:ok,
             %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => Enum.map(enum, &to_string/1)}
             }
             |> put_present("minItems", constraints[:min_length])
             |> put_present("maxItems", constraints[:max_length])}

          _other ->
            :error
        end

      _other ->
        :error
    end
  end

  defp resolved_type(type, constraints) do
    type = Ash.Type.get_type(type)

    cond do
      match?({:array, _}, type) ->
        {type, constraints}

      Ash.Type.NewType.new_type?(type) ->
        resolved_type(
          Ash.Type.NewType.subtype_of(type),
          Ash.Type.NewType.constraints(type, constraints)
        )

      true ->
        {type, constraints}
    end
  end

  defp put_format(property, format) when is_atom(format) and not is_nil(format),
    do: put_format(property, Atom.to_string(format))

  defp put_format(property, format) when format in @string_formats,
    do: Map.put(property, "format", format)

  defp put_format(property, _format), do: property

  defp put_pattern(property, %Regex{} = regex, :openai),
    do: Map.put(property, "pattern", Regex.source(regex))

  # Ash keeps a `match` constraint as `{Spark.Regex, :cache, [source, opts]}`.
  defp put_pattern(property, {module, function, args}, :openai),
    do: put_pattern(property, apply(module, function, args), :openai)

  defp put_pattern(property, pattern, :openai) when is_binary(pattern),
    do: Map.put(property, "pattern", pattern)

  defp put_pattern(property, _pattern, _dialect), do: property

  # An answered value comes back as the field's default, when it has the field's JSON type.
  defp put_default(property, nil), do: property

  defp put_default(%{"type" => "string"} = property, value) when is_binary(value),
    do: Map.put(property, "default", value)

  defp put_default(%{"type" => type} = property, value)
       when type in ["number", "integer"] and is_number(value),
       do: Map.put(property, "default", value)

  defp put_default(%{"type" => "boolean"} = property, value) when is_boolean(value),
    do: Map.put(property, "default", value)

  defp put_default(%{"type" => "array"} = property, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: Map.put(property, "default", value), else: property
  end

  defp put_default(property, _value), do: property

  # The tool's title, then one line per error as a tool error names it (`AshAi.Tool.Errors`),
  # with the error's variables filled in.
  defp message(tool, errors) do
    lines =
      Enum.map(errors, fn error ->
        text =
          error
          |> AshAi.ToToolError.to_tool_error()
          |> interpolate(Map.get(error, :vars) || [])

        "#{error.field}: #{text}"
      end)

    Enum.join(["#{Tool.title(tool)} needs more input." | Enum.uniq(lines)], "\n")
  end

  defp interpolate(text, vars) do
    Enum.reduce(vars, text, fn {key, value}, text ->
      String.replace(text, "%{#{key}}", to_string(value))
    end)
  end

  defp title(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp get(_map, _key), do: nil
end
