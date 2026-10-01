# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Tool.OpenAi do
  @moduledoc """
  The OpenAI Apps SDK tool descriptor fields an MCP tool carries (BLENDED-016, BLENDED-018).

    * `securitySchemes` — `[%{"type" => "noauth"} | %{"type" => "oauth2", "scopes" => [...]}]`,
      emitted at the tool's top level and mirrored in `_meta["securitySchemes"]`.
    * `_meta["openai/fileParams"]` — the top-level input fields that take files. Each such field
      is the object `{download_url, file_id, mime_type?, file_name?}` (or an array of it) with
      exactly the schema the Apps SDK requires, outside ash_ai's `input` envelope.

  Source: developers.openai.com/plugins/reference, "Tool descriptor parameters" and "File APIs".
  """

  @file_object %{
    "type" => "object",
    "properties" => %{
      "download_url" => %{"type" => "string"},
      "file_id" => %{"type" => "string"},
      "mime_type" => %{"type" => "string"},
      "file_name" => %{"type" => "string"}
    },
    "required" => ["download_url", "file_id"],
    "additionalProperties" => false
  }

  @file_keys ["download_url", "file_id", "mime_type", "file_name"]
  @max_files 20
  @max_url 2048
  @max_id 256

  @doc "The file object schema the Apps SDK requires."
  def file_object_schema, do: @file_object

  @doc "The most file objects one array-valued file field accepts."
  def max_files, do: @max_files

  @doc """
  The tool's resolved `securitySchemes`: the tool's own option, else the server's default, else
  `nil` (nothing is emitted). Each scheme is normalized to string keys; anything other than
  `noauth` or `oauth2` with a list of string scopes raises `ArgumentError`.
  """
  def security_schemes(%AshAi.Tool{security_schemes: schemes} = tool, default) do
    case schemes || default do
      nil -> nil
      list when is_list(list) -> Enum.map(list, &scheme!(tool, &1))
      other -> raise ArgumentError, "security_schemes must be a list, got: #{inspect(other)}"
    end
  end

  defp scheme!(tool, scheme) when is_map(scheme) do
    type = get(scheme, :type)
    scopes = get(scheme, :scopes)
    keys = scheme |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    cond do
      type in ["noauth", :noauth] and keys == ["type"] ->
        %{"type" => "noauth"}

      type in ["oauth2", :oauth2] and keys in [["type"], ["scopes", "type"]] and
          (is_nil(scopes) or (is_list(scopes) and Enum.all?(scopes, &is_binary/1))) ->
        %{"type" => "oauth2", "scopes" => scopes || []}

      true ->
        raise ArgumentError,
              "tool #{inspect(tool.name)}: a security scheme is %{type: \"noauth\"} or " <>
                "%{type: \"oauth2\", scopes: [String.t()]}, got: #{inspect(scheme)}"
    end
  end

  defp scheme!(tool, scheme),
    do:
      raise(
        ArgumentError,
        "tool #{inspect(tool.name)}: a security scheme must be a map, got: #{inspect(scheme)}"
      )

  @doc """
  The tool's file fields as `{name, :one | :many, required?}`, checked against its action: each
  must be a public argument of type `:map` or `{:array, :map}`. Raises `ArgumentError` otherwise.
  """
  def file_params(%AshAi.Tool{file_params: names}) when names in [nil, []], do: []

  def file_params(%AshAi.Tool{file_params: names, action: action} = tool) do
    Enum.map(names, fn name ->
      argument = Enum.find(action.arguments, &(&1.name == name))

      cond do
        is_nil(argument) or not argument.public? ->
          raise ArgumentError,
                "tool #{inspect(tool.name)}: file_params names #{inspect(name)}, which is not " <>
                  "a public argument of action #{inspect(action.name)}"

        map_type?(argument.type) ->
          {name, :one, not argument.allow_nil?}

        match?({:array, _}, argument.type) and map_type?(elem(argument.type, 1)) ->
          {name, :many, not argument.allow_nil?}

        true ->
          raise ArgumentError,
                "tool #{inspect(tool.name)}: file_params argument #{inspect(name)} must be of " <>
                  "type :map or {:array, :map}, got: #{inspect(argument.type)}"
      end
    end)
  end

  defp map_type?(type), do: Ash.Type.get_type(type) == Ash.Type.Map

  @doc """
  Moves the file fields out of the `input` envelope of a generated input schema (string keys)
  and declares them at the top level with the Apps SDK file schema.
  """
  def hoist_schema(schema, tool, strict?) do
    case file_params(tool) do
      [] -> schema
      fields -> Enum.reduce(fields, schema, &hoist_field(&2, &1, strict?))
    end
  end

  defp hoist_field(schema, {name, cardinality, required?}, strict?) do
    key = to_string(name)

    file_schema =
      case cardinality do
        :one -> @file_object
        :many -> %{"type" => "array", "items" => @file_object}
      end

    file_schema =
      if strict? and not required?,
        do: %{"anyOf" => [file_schema, %{"type" => "null"}]},
        else: file_schema

    schema =
      update_in(schema, ["properties"], fn properties ->
        properties
        |> drop_from_input(key)
        |> Map.put(key, file_schema)
      end)

    required = Map.get(schema, "required", [])

    required =
      if (strict? or required?) and key not in required, do: required ++ [key], else: required

    schema
    |> Map.put("required", required)
    |> drop_empty_input(strict?)
  end

  defp drop_from_input(%{"input" => input} = properties, key) do
    input = unwrap_nullable(input)

    input =
      input
      |> Map.update("properties", %{}, &Map.delete(&1, key))
      |> Map.update("required", [], &List.delete(&1, key))

    Map.put(properties, "input", input)
  end

  defp drop_from_input(properties, _key), do: properties

  defp unwrap_nullable(%{"anyOf" => [object, %{"type" => "null"}]}), do: object
  defp unwrap_nullable(input), do: input

  # BLENDED-011: with no input property left, the envelope goes, and `{}` (with the file fields)
  # is a valid call. With input left but nothing in it required, `input` is not required.
  defp drop_empty_input(%{"properties" => %{"input" => input}} = schema, strict?) do
    cond do
      map_size(input["properties"] || %{}) == 0 ->
        schema
        |> update_in(["properties"], &Map.delete(&1, "input"))
        |> Map.update("required", [], &List.delete(&1, "input"))

      (input["required"] || []) == [] and not strict? ->
        Map.update(schema, "required", [], &List.delete(&1, "input"))

      true ->
        schema
    end
  end

  defp drop_empty_input(schema, _strict?), do: schema

  @doc "The tool's `_meta[\"openai/fileParams\"]`, or `%{}` when it has no file fields."
  def file_params_meta(tool) do
    case file_params(tool) do
      [] -> %{}
      fields -> %{"openai/fileParams" => Enum.map(fields, fn {name, _, _} -> to_string(name) end)}
    end
  end

  @doc """
  Checks the file fields of a call's arguments and puts them back into its `input`, as the action
  takes them. Returns `{:ok, arguments}` or `{:error, text}` naming the field; a call is never
  partially reconstructed.
  """
  def reconstruct_arguments(tool, arguments) when is_map(arguments) do
    tool
    |> file_params()
    |> Enum.reduce_while({:ok, arguments}, fn {name, cardinality, required?}, {:ok, acc} ->
      key = to_string(name)

      case check_value(key, cardinality, required?, Map.get(acc, key)) do
        {:ok, :absent} ->
          {:cont, {:ok, Map.delete(acc, key)}}

        {:ok, value} ->
          input = Map.get(acc, "input") || %{}

          {:cont, {:ok, acc |> Map.delete(key) |> Map.put("input", Map.put(input, key, value))}}

        {:error, text} ->
          {:halt, {:error, text}}
      end
    end)
  end

  def reconstruct_arguments(_tool, arguments), do: {:ok, arguments}

  defp check_value(key, _cardinality, true, nil), do: {:error, "#{key} is required: #{shape()}"}
  defp check_value(_key, _cardinality, false, nil), do: {:ok, :absent}

  defp check_value(key, :one, _required?, value) do
    case check_file(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, "#{key} #{reason}: #{shape()}"}
    end
  end

  defp check_value(key, :many, _required?, values) when is_list(values) do
    cond do
      values == [] ->
        {:error, "#{key} must list at least one file: #{shape()}"}

      length(values) > @max_files ->
        {:error, "#{key} lists #{length(values)} files; at most #{@max_files} are accepted"}

      true ->
        values
        |> Enum.with_index()
        |> Enum.find_value({:ok, values}, fn {value, index} ->
          case check_file(value) do
            :ok -> nil
            {:error, reason} -> {:error, "#{key}[#{index}] #{reason}: #{shape()}"}
          end
        end)
    end
  end

  defp check_value(key, :many, _required?, _value),
    do: {:error, "#{key} must be an array of file objects: #{shape()}"}

  defp check_file(value) when is_map(value) do
    extra = value |> Map.keys() |> Enum.reject(&(&1 in @file_keys))

    cond do
      extra != [] ->
        {:error, "has unknown fields #{Enum.map_join(Enum.sort(extra), ", ", &inspect/1)}"}

      not text?(value["download_url"], @max_url) ->
        {:error, "needs download_url, a string of at most #{@max_url} characters"}

      not text?(value["file_id"], @max_id) ->
        {:error, "needs file_id, a string of at most #{@max_id} characters"}

      not optional_text?(value["mime_type"]) ->
        {:error, "has a mime_type that is not a string"}

      not optional_text?(value["file_name"]) ->
        {:error, "has a file_name that is not a string"}

      true ->
        :ok
    end
  end

  defp check_file(_value), do: {:error, "must be a file object"}

  defp text?(value, max), do: is_binary(value) and value != "" and String.length(value) <= max
  defp optional_text?(value), do: is_nil(value) or is_binary(value)

  defp shape, do: "a file object {download_url, file_id, mime_type?, file_name?}"

  defp get(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
