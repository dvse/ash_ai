# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Tool.Schema do
  @moduledoc """
  Generates JSON schemas for tool parameters.

  Supports both strict and non-strict modes:
  - strict mode transforms schemas for OpenAI-compatible strict tool calling
  - non-strict mode strips `additionalProperties` for providers like Gemini
  """

  @doc """
  Generates a JSON schema for the given tool definition.
  """
  def for_tool(
        %AshAi.Tool{
          domain: domain,
          resource: resource,
          action: action,
          action_parameters: action_parameters,
          arguments: tool_arguments,
          identity: identity,
          get_by: get_by
        } = tool,
        opts \\ []
      ) do
    strict? = Keyword.get(opts, :strict?, true)

    # BLENDED-004: from ash_hyperlang lib/ash_hyperlang/domain.ex:205 — `refine?: false`
    # omits the read query envelope, exactly as `action_parameters: []` does.
    action_parameters = if tool.refine? == false, do: [], else: action_parameters

    for_action(domain, resource, action, action_parameters, tool_arguments,
      strict?: strict?,
      identity: identity,
      get_by: get_by,
      full_filter_schema?: Map.get(tool, :full_filter_schema?, false)
    )
    # BLENDED-018: file fields leave the `input` envelope (OpenAI Apps SDK `openai/fileParams`).
    |> AshAi.Tool.OpenAi.hoist_schema(tool, strict?)
  end

  @doc """
  Generates a JSON schema for a given action.
  """
  def for_action(
        _domain,
        resource,
        action,
        action_parameters \\ nil,
        tool_arguments \\ [],
        opts \\ []
      ) do
    strict? = Keyword.get(opts, :strict?, true)
    identity = Keyword.get(opts, :identity, nil)
    get_by = Keyword.get(opts, :get_by, nil)

    get_by_fields =
      if action.type == :read do
        AshAi.Tool.get_by_fields(resource, get_by)
      else
        []
      end

    attributes =
      if action.type in [:action, :read] do
        %{}
      else
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&(&1.name in action.accept && &1.writable?))
        |> Map.new(fn attribute ->
          value =
            AshAi.OpenApi.resource_write_attribute_type(
              attribute,
              resource,
              action.type
            )

          {attribute.name, value}
        end)
      end

    properties =
      action.arguments
      |> Enum.filter(& &1.public?)
      |> Enum.reduce(attributes, fn argument, attrs ->
        value = AshAi.OpenApi.resource_write_attribute_type(argument, resource, :create)
        Map.put(attrs, argument.name, value)
      end)

    properties =
      Enum.reduce(tool_arguments, properties, fn argument, props ->
        tool_argument = %{
          name: argument.name,
          type: argument.type,
          constraints: argument.constraints,
          allow_nil?: argument.allow_nil?,
          default: argument.default,
          description: argument.description
        }

        Map.put(
          props,
          argument.name,
          AshAi.OpenApi.resource_write_attribute_type(tool_argument, resource, :create)
        )
      end)

    required_tool_arguments =
      tool_arguments
      |> Enum.filter(&(not &1.allow_nil?))
      |> Enum.map(& &1.name)

    required_action_arguments =
      AshAi.OpenApi.required_write_attributes(resource, action.arguments, action)

    required_inputs = Enum.uniq(required_action_arguments ++ required_tool_arguments)

    props_with_input =
      if Enum.empty?(properties) do
        %{}
      else
        %{
          input: %{
            type: :object,
            properties: properties,
            additionalProperties: false,
            required: required_inputs
          }
        }
      end

    # BLENDED-011: from ash_hyperlang lib/ash_hyperlang/capability.ex:78
    # (`required_arguments?/2`) — when no input is required, `input` itself is optional, so
    # `{}` is a valid call.
    required_top_level =
      if required_inputs == [], do: [], else: Map.keys(props_with_input)

    %{
      type: :object,
      properties:
        add_action_specific_properties(props_with_input, resource, action, action_parameters,
          strict?: strict?,
          identity: identity,
          get_by_fields: get_by_fields,
          full_filter_schema?: Keyword.get(opts, :full_filter_schema?, false)
        ),
      required: required_top_level ++ Enum.map(get_by_fields, & &1.name),
      additionalProperties: false
    }
    |> Jason.encode!()
    |> Jason.decode!()
    |> then(fn schema ->
      if strict? do
        make_strict_schema(schema)
      else
        strip_additional_properties(schema)
      end
    end)
  end

  # Recursively transforms a JSON schema to be OpenAI strict-mode compliant:
  # - Every object gets `additionalProperties: false`
  # - Every non-required property is made nullable
  defp make_strict_schema(schema) when is_map(schema) do
    schema =
      if schema["type"] == "object" && is_map(schema["properties"]) do
        already_required = MapSet.new(schema["required"] || [])

        updated_props =
          Map.new(schema["properties"], fn {k, v} ->
            if MapSet.member?(already_required, k) do
              {k, make_strict_schema(v)}
            else
              {k, make_nullable(make_strict_schema(v))}
            end
          end)

        schema
        |> Map.put("properties", updated_props)
        |> Map.put("required", Map.keys(schema["properties"]))
        |> Map.put("additionalProperties", false)
      else
        schema
      end

    schema
    |> then(fn s ->
      case s["anyOf"] do
        nil -> s
        types -> Map.put(s, "anyOf", Enum.map(types, &make_strict_schema/1))
      end
    end)
    |> then(fn s ->
      case s["items"] do
        nil -> s
        items -> Map.put(s, "items", make_strict_schema(items))
      end
    end)
  end

  defp make_strict_schema(schema) when is_list(schema),
    do: Enum.map(schema, &make_strict_schema/1)

  defp make_strict_schema(schema), do: schema

  # Makes a schema accept null, preferring the compact `"type": [..., "null"]`
  # form over an `anyOf` wrapper. `enum` validates independently of `type`, so
  # null is appended there too.
  defp make_nullable(%{"type" => type} = schema) when is_binary(type) or is_list(type) do
    types = List.wrap(type)

    if "null" in types do
      schema
    else
      schema
      |> Map.put("type", types ++ ["null"])
      |> then(fn s ->
        case s["enum"] do
          enum when is_list(enum) -> Map.put(s, "enum", enum ++ [nil])
          _ -> s
        end
      end)
    end
  end

  defp make_nullable(schema), do: %{"anyOf" => [%{"type" => "null"}, schema]}

  # Recursively removes `additionalProperties` from a schema map.
  defp strip_additional_properties(schema) when is_map(schema) do
    schema
    |> Map.delete("additionalProperties")
    |> Map.new(fn {k, v} -> {k, strip_additional_properties(v)} end)
  end

  defp strip_additional_properties(schema) when is_list(schema) do
    Enum.map(schema, &strip_additional_properties/1)
  end

  defp strip_additional_properties(schema), do: schema

  @all_result_types [:run_query, :count, :exists, :aggregate]

  # `action_parameters` may contain a `result_type: [...]` entry restricting which
  # result types are offered. `:run_query` is always included.
  defp extract_result_types(nil), do: {@all_result_types, nil}

  defp extract_result_types(action_parameters) do
    case List.keyfind(action_parameters, :result_type, 0) do
      {:result_type, types} ->
        {Enum.uniq([:run_query | types]),
         Enum.map(action_parameters, fn
           {:result_type, _types} -> :result_type
           other -> other
         end)}

      nil ->
        {@all_result_types, action_parameters}
    end
  end

  defp add_action_specific_properties(properties, resource, action, action_parameters, opts)

  defp add_action_specific_properties(
         properties,
         resource,
         %{type: :read, pagination: pagination},
         action_parameters,
         opts
       ) do
    case Keyword.get(opts, :get_by_fields, []) do
      [_ | _] = get_by_fields ->
        get_by_fields
        |> Map.new(fn field ->
          {field.name, AshAi.OpenApi.resource_write_attribute_type(field, resource, :create)}
        end)
        |> then(&Map.merge(properties, &1))

      [] ->
        strict? = Keyword.get(opts, :strict?, true)
        {allowed_result_types, action_parameters} = extract_result_types(action_parameters)

        read_query_properties(
          properties,
          resource,
          pagination,
          action_parameters,
          strict?,
          allowed_result_types,
          opts
        )
    end
  end

  defp add_action_specific_properties(
         properties,
         resource,
         %{type: type},
         _action_parameters,
         opts
       )
       when type in [:update, :destroy] do
    identity = Keyword.get(opts, :identity, nil)

    # Mirror `AshAi.Tool.Execution.identity_filter/3`: address records by the
    # configured identity (or the primary key by default, or nothing when `false`).
    identity_properties =
      resource
      |> AshAi.Tool.identity_keys(identity)
      |> Map.new(fn key ->
        value =
          Ash.Resource.Info.attribute(resource, key)
          |> AshAi.OpenApi.resource_write_attribute_type(resource, type)

        {key, value}
      end)

    Map.merge(properties, identity_properties)
  end

  defp add_action_specific_properties(properties, _resource, _action, _action_parameters, _opts),
    do: properties

  defp read_query_properties(
         properties,
         resource,
         pagination,
         action_parameters,
         strict?,
         allowed_result_types,
         opts
       ) do
    aggregate_fields =
      Ash.Resource.Info.fields(resource, [
        :attributes,
        :aggregates,
        :calculations
      ])
      |> Enum.filter(& &1.public?)
      |> Enum.map(& &1.name)

    paginated? = match?(%Ash.Resource.Actions.Read.Pagination{}, pagination)

    scalar_result_types =
      for type <- ["run_query", "count", "exists"],
          String.to_existing_atom(type) in allowed_result_types,
          do: type

    scalar_result_type_schema = %{
      type: :string,
      description:
        scalar_result_types
        |> Enum.map_join(", or ", fn
          "run_query" when paginated? ->
            "run the query returning a page of results (check `has_more` to see whether further pages exist)"

          "run_query" ->
            "run the query returning the matching records (up to `limit`)"

          "count" ->
            "return a count of results"

          "exists" ->
            "check if any results exist"
        end)
        |> String.capitalize(),
      enum: scalar_result_types
    }

    aggregate_result_type_schema = %{
      type: :object,
      description: "Aggregate a field across all results",
      additionalProperties: false,
      required: [:aggregate, :field],
      properties: %{
        aggregate: %{
          type: :string,
          description: "The aggregate function to use",
          enum: [:max, :min, :sum, :avg, :count]
        },
        field: %{
          type: :string,
          description: "The field to aggregate",
          enum: aggregate_fields
        }
      }
    }

    result_type_schema =
      cond do
        :aggregate not in allowed_result_types ->
          Map.merge(scalar_result_type_schema, %{default: "run_query"})

        strict? ->
          %{
            default: "run_query",
            description: "The type of result to return",
            anyOf: [scalar_result_type_schema, aggregate_result_type_schema]
          }

        true ->
          %{
            default: "run_query",
            description: "The type of result to return",
            oneOf: [
              scalar_result_type_schema,
              aggregate_result_type_schema
              |> Map.delete(:description)
              |> Map.delete(:additionalProperties)
            ]
          }
      end

    {filterable_fields, available_operators} =
      Ash.Resource.Info.fields(resource, [:attributes, :aggregates, :calculations])
      |> Enum.filter(
        &(&1.public? && &1.filterable? && AshAi.OpenApi.filterable_field?(&1, resource))
      )
      |> Enum.reduce({[], MapSet.new()}, fn field, {fields, ops} ->
        case AshAi.OpenApi.raw_filter_type(field, resource) do
          nil ->
            {fields, ops}

          %{properties: props} ->
            field_ops = props |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()
            {[field.name | fields], MapSet.union(ops, field_ops)}

          _ ->
            {fields, ops}
        end
      end)
      |> then(fn {fields, ops} ->
        {Enum.reverse(fields), ops |> MapSet.to_list() |> Enum.sort()}
      end)

    filter_schema =
      cond do
        !Keyword.get(opts, :full_filter_schema?, false) ->
          %{
            type: :object,
            description: """
            A filter to apply to the query: either a condition \
            {"field": ..., "operator": ..., "value": ...} or an \
            {"and": [...]} / {"or": [...]} group of conditions and groups (nestable). \
            Operators: #{Enum.join(available_operators, ", ")}. \
            For 'is_nil' the value is true or false; for 'in' the value is an array. \
            Fields: #{Enum.join(filterable_fields, ", ")}.\
            """
          }

        strict? ->
          condition_schema = %{
            type: :object,
            additionalProperties: false,
            required: [:field, :operator, :value],
            properties: %{
              field: %{
                type: :string,
                description: "The field to filter on",
                enum: filterable_fields
              },
              operator: %{
                type: :string,
                description:
                  "The comparison operator. Use 'is_nil' with true/false to check for null values.",
                enum: available_operators
              },
              value: %{
                description:
                  "The comparison value. For 'is_nil' use true or false. For 'in'/'not_in' use an array of values.",
                anyOf: [
                  %{type: :string},
                  %{type: :number},
                  %{type: :boolean},
                  %{type: :null},
                  %{
                    type: :array,
                    items: %{anyOf: [%{type: :string}, %{type: :number}, %{type: :boolean}]}
                  }
                ]
              }
            }
          }

          %{
            type: :array,
            description:
              "Filter conditions. Top-level entries are ANDed together. Use an {\"or\": [...]} entry to OR multiple conditions.",
            items: %{
              anyOf: [
                condition_schema,
                %{
                  type: :object,
                  additionalProperties: false,
                  required: [:or],
                  properties: %{
                    or: %{
                      type: :array,
                      description: "A list of conditions where any one must match.",
                      items: condition_schema
                    }
                  }
                }
              ]
            }
          }

        true ->
          %{
            type: :object,
            description: "Filter results",
            properties:
              Ash.Resource.Info.fields(resource, [:attributes, :aggregates, :calculations])
              |> Enum.filter(
                &(&1.public? && &1.filterable? && AshAi.OpenApi.filterable_field?(&1, resource))
              )
              |> Map.new(fn field ->
                {field.name, AshAi.OpenApi.raw_filter_type(field, resource)}
              end)
          }
      end

    Map.merge(properties, %{
      filter: filter_schema,
      result_type: result_type_schema,
      limit: %{
        type: :integer,
        description:
          if(paginated?,
            do: "The maximum number of records to return in one page",
            else: "The maximum number of records to return"
          ),
        default:
          case pagination do
            %Ash.Resource.Actions.Read.Pagination{default_limit: limit} when is_integer(limit) ->
              limit

            _ ->
              25
          end
      },
      sort: %{
        type: :array,
        items: %{
          type: :object,
          required: [:field, :direction],
          properties:
            %{
              field: %{
                type: :string,
                description: "The field to sort by",
                enum:
                  Ash.Resource.Info.fields(resource, [
                    :attributes,
                    :calculations,
                    :aggregates
                  ])
                  |> Enum.filter(&(&1.public? && &1.sortable?))
                  |> Enum.map(& &1.name)
              },
              direction: %{
                type: :string,
                description: "The direction to sort by",
                enum: ["asc", "desc"]
              }
            }
            |> add_input_for_fields(resource)
        }
      }
    })
    |> Map.merge(query_offset_property(pagination))
    |> then(fn map ->
      if action_parameters do
        Map.take(map, action_parameters ++ [:input])
      else
        map
      end
    end)
    |> Map.merge(pagination_properties(pagination))
  end

  # Non-paginated actions accept an `offset` applied directly to the query; it is
  # an ordinary query control, so `action_parameters` may hide it.
  defp query_offset_property(%Ash.Resource.Actions.Read.Pagination{}), do: %{}

  defp query_offset_property(_pagination) do
    %{
      offset: %{
        type: :integer,
        description: "The number of records to skip",
        default: 0
      }
    }
  end

  # Paginated actions always expose the controls their pagination supports, even
  # when `action_parameters` narrows the other query controls: the page they
  # return carries the value to pass for the next page, so the LLM must be able
  # to pass it. Keyset is the default when available. Mirrors
  # `AshAi.Tool.Execution` page option selection.
  defp pagination_properties(%Ash.Resource.Actions.Read.Pagination{} = pagination) do
    offset =
      if pagination.offset? do
        %{
          offset: %{
            type: :integer,
            description:
              if(pagination.keyset?,
                do:
                  "The number of records to skip. Pages use keyset cursors by default; pass a positive offset to page by position instead, then pass the `next_offset` from that page for the following one.",
                else:
                  "The number of records to skip. Pass the `next_offset` from a previous page to fetch the following page."
              ),
            default: 0
          }
        }
      else
        %{}
      end

    keyset =
      if pagination.keyset? do
        %{
          after: %{
            type: :string,
            description:
              "Fetch the page after this keyset cursor. Pass the `end_keyset` from a previous page to fetch the following page."
          },
          before: %{
            type: :string,
            description:
              "Fetch the page before this keyset cursor. Pass the `start_keyset` from a previous page to fetch the preceding page."
          }
        }
      else
        %{}
      end

    Map.merge(offset, keyset)
  end

  defp pagination_properties(_pagination), do: %{}

  defp add_input_for_fields(sort_obj, resource) do
    resource
    |> Ash.Resource.Info.fields([:calculations])
    |> Enum.filter(&(&1.public? && &1.sortable? && !Enum.empty?(&1.arguments)))
    |> case do
      [] ->
        sort_obj

      fields ->
        input_for_fields = %{
          type: :object,
          properties:
            Map.new(fields, fn field ->
              inputs =
                Enum.map(field.arguments, fn argument ->
                  value =
                    AshAi.OpenApi.resource_write_attribute_type(
                      argument,
                      resource,
                      :create
                    )

                  {argument.name, value}
                end)

              required =
                Enum.flat_map(field.arguments, fn argument ->
                  if argument.allow_nil? do
                    []
                  else
                    [argument.name]
                  end
                end)

              {field.name,
               %{
                 type: :object,
                 properties: Map.new(inputs),
                 required: required
               }}
            end)
        }

        Map.put(sort_obj, :input_for_fields, input_for_fields)
    end
  end

  # ---------------------------------------------------------------------------
  # BLENDED-010: output schemas
  #
  # Types come from core Ash `Ash.Info.Manifest` (the generator's `ActionBuilder` `returns`,
  # `ResourceBuilder` fields/relationships and `TypeResolver`), the same source ash_hyperlang
  # documents its outputs from (ash_hyperlang lib/ash_hyperlang/capability.ex:9). The shapes
  # mirror `AshAi.Tool.Execution` and `AshAi.Serializer` exactly: select/load, omitted nil
  # and not-loaded record fields, union tagging, Decimal-as-string and the forbidden-field
  # rendering of BLENDED-012.
  # ---------------------------------------------------------------------------

  alias Ash.Info.Manifest.Generator.{ActionBuilder, ResourceBuilder, TypeResolver}

  @forbidden_marker %{
    "type" => "object",
    "properties" => %{"opaque" => %{"type" => "string", "enum" => ["forbidden"]}},
    "required" => ["opaque"],
    "additionalProperties" => false
  }

  @doc """
  The MCP `outputSchema` for a tool, or `nil`.

  Emitted when `output_schema?` is set (the default) and every result the tool can return
  is a JSON object, i.e. is always carried as `structuredContent`. See `result_for_tool/1`.
  """
  def output_for_tool(%AshAi.Tool{output_schema?: false}), do: nil

  def output_for_tool(%AshAi.Tool{} = tool) do
    case result_for_tool(tool) do
      %{"type" => "object"} = schema -> schema
      _other -> nil
    end
  end

  @doc """
  The JSON Schema of a tool's serialized result: the JSON text content of a successful
  `tools/call`, which is also its `structuredContent` whenever it is an object.

  Returns `nil` for generic actions without a return type, whose result is the bare
  string `"success"`.
  """
  def result_for_tool(%AshAi.Tool{} = tool) do
    ctx = %{forbidden_fields: tool.forbidden_fields || :hide, visited: MapSet.new()}

    case tool.action.type do
      :read -> read_result(tool, ctx)
      :action -> generic_result(tool, ctx)
      _write -> record_schema(tool.resource, tool.select, tool.load, ctx)
    end
  end

  defp read_result(%AshAi.Tool{get_by: get_by} = tool, ctx) when not is_nil(get_by) do
    record_schema(tool.resource, tool.select, tool.load, ctx)
  end

  defp read_result(tool, ctx) do
    tool
    |> offered_result_types()
    |> Enum.map(&read_result_type(&1, tool, ctx))
    |> any_of()
  end

  # Mirrors `extract_result_types/1` and the `Map.take/2` in `read_query_properties/7`: the
  # result types the input schema offers.
  defp offered_result_types(%AshAi.Tool{refine?: false}), do: [:run_query]
  defp offered_result_types(%AshAi.Tool{action_parameters: nil}), do: @all_result_types

  defp offered_result_types(%AshAi.Tool{action_parameters: action_parameters}) do
    case extract_result_types(action_parameters) do
      {types, params} -> if :result_type in params, do: types, else: [:run_query]
    end
  end

  defp read_result_type(:run_query, tool, ctx) do
    records = %{
      "type" => "array",
      "items" => record_schema(tool.resource, tool.select, tool.load, ctx)
    }

    case tool.action.pagination do
      %Ash.Resource.Actions.Read.Pagination{} = pagination ->
        [
          pagination.offset? && offset_page(records),
          pagination.keyset? && keyset_page(records)
        ]
        |> Enum.filter(& &1)
        |> any_of()

      _unpaginated ->
        records
    end
  end

  defp read_result_type(:count, _tool, _ctx), do: %{"type" => "integer"}
  defp read_result_type(:exists, _tool, _ctx), do: %{"type" => "boolean"}

  # Mirrors `AshAi.Tool.Execution.execute_read/5`: the aggregate's result type comes from
  # the field's declared type. A combination without a type (e.g. `avg` of an aggregate
  # field, whose declared type is `nil`) is a tool error, so it contributes no result.
  defp read_result_type(:aggregate, tool, ctx) do
    for field <-
          Ash.Resource.Info.fields(tool.resource, [:attributes, :aggregates, :calculations]),
        field.public?,
        kind <- [:max, :min, :sum, :avg, :count],
        {:ok, type, constraints} <-
          [Ash.Query.Aggregate.kind_to_type(kind, field.type, field.constraints || [])] do
      schema = type |> TypeResolver.resolve(constraints) |> value_schema([], ctx)

      # `avg` is typed `:float`, but the data layer may return a `Decimal`, which the
      # serializer passes through and Jason encodes as a string.
      if kind == :avg, do: any_of([schema, %{"type" => "string"}]), else: schema
    end
    |> Enum.concat([%{"type" => "null"}])
    |> any_of()
  end

  defp offset_page(records) do
    page(records, %{
      "offset" => %{"type" => "integer"},
      "next_offset" => %{"type" => ["integer", "null"]}
    })
  end

  defp keyset_page(records) do
    page(records, %{
      "start_keyset" => %{"type" => ["string", "null"]},
      "end_keyset" => %{"type" => ["string", "null"]}
    })
  end

  defp page(records, properties) do
    properties =
      Map.merge(properties, %{
        "results" => records,
        "limit" => %{"type" => "integer"},
        "has_more" => %{"type" => "boolean"},
        "count" => %{"type" => "integer"}
      })

    %{
      "type" => "object",
      "properties" => properties,
      "required" => properties |> Map.keys() |> List.delete("count") |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  defp generic_result(%AshAi.Tool{action: %{returns: nil}}, _ctx), do: nil

  defp generic_result(tool, ctx) do
    schema =
      tool.resource
      |> ActionBuilder.build(tool.action)
      |> Map.fetch!(:returns)
      |> value_schema(tool.load, ctx)

    if tool.action.allow_nil?, do: nullable(schema), else: schema
  end

  # A resource record as `AshAi.Serializer.serialize_attributes/3` renders it: the selected
  # (default: public) attributes plus loaded fields, each present only when loaded, allowed
  # and non-nil. A load function is resolved per call, so its extra fields are not known.
  defp record_schema(resource, select, load, ctx) do
    if MapSet.member?(ctx.visited, resource) do
      %{"type" => "object"}
    else
      ctx = %{ctx | visited: MapSet.put(ctx.visited, resource)}

      manifest =
        ResourceBuilder.build(resource,
          include_private_attributes?: true,
          include_private_calculations?: true,
          include_private_aggregates?: true,
          include_private_relationships?: true
        )

      load_list = if is_list(load), do: load, else: []

      properties =
        (select || Enum.map(Ash.Resource.Info.public_attributes(resource), & &1.name))
        |> Enum.concat(Enum.map(load_list, &load_key/1))
        |> Enum.uniq()
        |> Enum.flat_map(fn name ->
          case record_field_schema(manifest, resource, name, nested_load(load_list, name), ctx) do
            nil -> []
            schema -> [{to_string(name), forbidden(schema, ctx)}]
          end
        end)
        |> Map.new()

      %{"type" => "object", "properties" => properties}
      |> then(&if(is_list(load), do: Map.put(&1, "additionalProperties", false), else: &1))
    end
  end

  defp record_field_schema(manifest, resource, name, load, ctx) do
    cond do
      field = manifest.fields[name] ->
        value_schema(field.type, load, ctx)

      relationship = manifest.relationships[name] ->
        record = record_schema(relationship.destination, nil, load, ctx)

        if relationship.cardinality == :many,
          do: %{"type" => "array", "items" => record},
          else: record

      # A calculation with `field?: false` is absent from the manifest but still serialized
      # when loaded.
      field = Ash.Resource.Info.field(resource, name) ->
        field.type |> TypeResolver.resolve(field.constraints || []) |> value_schema(load, ctx)

      # Not a field: the serializer skips it (`!field -> acc`).
      true ->
        nil
    end
  end

  defp load_key({key, _value}), do: key
  defp load_key(key), do: key

  defp nested_load(load, name) do
    Enum.find_value(load, [], fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  # BLENDED-012: from ash_hyperlang lib/ash_hyperlang/executor.ex:4398 — `:display` renders
  # a forbidden field as `%{opaque: :forbidden}`.
  defp forbidden(schema, %{forbidden_fields: :display}),
    do: %{"anyOf" => [schema, @forbidden_marker]}

  defp forbidden(schema, _ctx), do: schema

  # The non-nil value of a type, as `AshAi.Serializer.serialize_value/5` renders it.
  # Named types: an enum resolves to its values; a NewType is unwrapped with its use-site
  # constraints, as `AshAi.Serializer` does (`flatten_new_type/2`).
  defp value_schema(%{kind: :type_ref, module: module, constraints: constraints}, load, ctx) do
    if Ash.Type.NewType.new_type?(module) do
      module
      |> Ash.Type.NewType.subtype_of()
      |> TypeResolver.resolve(Ash.Type.NewType.constraints(module, constraints))
    else
      TypeResolver.resolve_definition(module)
    end
    |> value_schema(load, ctx)
  end

  defp value_schema(%{kind: :array} = type, load, ctx) do
    item = value_schema(type.item_type, load, ctx)
    item = if type.constraints[:nil_items?], do: nullable(item), else: item
    %{"type" => "array", "items" => item}
  end

  defp value_schema(%{kind: kind}, _load, _ctx)
       when kind in [
              :string,
              :ci_string,
              :uuid,
              :decimal,
              :date,
              :datetime,
              :utc_datetime,
              :utc_datetime_usec,
              :naive_datetime,
              :time,
              :time_usec,
              :binary,
              :atom
            ],
       do: %{"type" => "string"}

  defp value_schema(%{kind: :integer}, _load, _ctx), do: %{"type" => "integer"}
  defp value_schema(%{kind: :float}, _load, _ctx), do: %{"type" => "number"}
  defp value_schema(%{kind: :boolean}, _load, _ctx), do: %{"type" => "boolean"}

  defp value_schema(%{kind: :enum, values: values}, _load, _ctx),
    do: %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}

  defp value_schema(%{kind: kind, resource_module: resource}, load, ctx)
       when kind in [:resource, :embedded_resource],
       do: record_schema(resource, nil, load, ctx)

  defp value_schema(%{kind: :union, members: members}, load, ctx) do
    members
    |> Enum.map(&union_member_schema(&1, load, ctx))
    |> any_of()
  end

  defp value_schema(%{kind: kind, fields: [_ | _] = fields} = type, load, ctx)
       when kind in [:map, :keyword, :struct] do
    # Map and keyword values carry only the fields they contain; a struct with an
    # `instance_of` module always carries every declared field.
    required = if kind == :struct and type.instance_of, do: fields, else: []
    fields_schema(fields, required, load, ctx)
  end

  defp value_schema(%{kind: :tuple, element_types: [_ | _] = fields}, load, ctx),
    do: fields_schema(fields, fields, load, ctx)

  defp value_schema(%{kind: :map}, _load, _ctx), do: %{"type" => "object"}

  # `term`, `unknown`, `duration`, and field-less structs/keywords/tuples are passed to
  # Jason as-is.
  defp value_schema(_type, _load, _ctx), do: %{}

  defp fields_schema(fields, required, load, ctx) do
    %{
      "type" => "object",
      "properties" =>
        Map.new(fields, fn field ->
          schema = value_schema(field.type, load, ctx)
          {to_string(field.name), if(field.allow_nil?, do: nullable(schema), else: schema)}
        end),
      "required" => Enum.map(required, &to_string(&1.name)),
      "additionalProperties" => false
    }
  end

  # `%Ash.Union{}` values: a member serialized to a map gains a `type` key naming the
  # member; any other member is wrapped as `%{type: member, value: serialized}`.
  defp union_member_schema(%{name: name, type: type}, load, ctx) do
    tag = %{"type" => "string", "enum" => [to_string(name)]}

    case value_schema(type, load, ctx) do
      %{"type" => "object"} = object ->
        object
        |> Map.update("properties", %{"type" => tag}, &Map.put(&1, "type", tag))
        |> Map.update("required", ["type"], &Enum.uniq(["type" | &1]))

      schema ->
        wrapped = %{
          "type" => "object",
          "properties" => %{"type" => tag, "value" => schema},
          "required" => ["type", "value"],
          "additionalProperties" => false
        }

        # An untyped member may serialize to a map (tagged in place) or anything else
        # (wrapped).
        if schema == %{} do
          any_of([
            wrapped,
            %{"type" => "object", "properties" => %{"type" => tag}, "required" => ["type"]}
          ])
        else
          wrapped
        end
    end
  end

  defp nullable(schema) when schema == %{}, do: schema
  defp nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  # One schema stays as is; object-only alternatives keep `"type": "object"` at the root so
  # they still qualify as an MCP `outputSchema`.
  defp any_of(schemas) do
    case Enum.uniq(schemas) do
      [schema] ->
        schema

      schemas ->
        if Enum.all?(schemas, &match?(%{"type" => "object"}, &1)) do
          %{"type" => "object", "anyOf" => schemas}
        else
          %{"anyOf" => schemas}
        end
    end
  end
end
