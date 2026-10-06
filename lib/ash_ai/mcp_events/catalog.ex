# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Catalog do
  @moduledoc """
  The event catalog of a domain (BLENDED-026): its storage, its declared and default events, their
  schemas, argument normalization, facts, matching and payloads. Everything here is derived from
  compiled DSL; listing reads no data.
  """

  alias AshAi.McpEvent, as: Event
  alias AshAi.McpEvents.Info

  @type storage :: %{
          domain: module(),
          subscription: module(),
          occurrence: module(),
          delivery: module(),
          sender: module(),
          sender_options: keyword(),
          actor_persister: module() | nil,
          defaults?: boolean()
        }

  @doc "The domain's event storage, or nil when it names none."
  @spec storage(module()) :: storage() | nil
  def storage(domain) do
    if is_atom(domain) and not is_nil(domain) and Code.ensure_loaded?(domain) and
         function_exported?(domain, :spark_dsl_config, 0) and AshAi in Spark.extensions(domain) and
         Info.storage?(domain) do
      %{
        domain: domain,
        subscription: option(domain, :subscription),
        occurrence: option(domain, :occurrence),
        delivery: option(domain, :delivery),
        sender: option(domain, :sender) || AshAi.McpEvents.Sender.Req,
        sender_options: option(domain, :sender_options) || [],
        actor_persister: option(domain, :actor_persister),
        defaults?: option(domain, :defaults?, true)
      }
    end
  end

  defp option(domain, name, default \\ nil),
    do: Spark.Dsl.Extension.get_opt(domain, [:mcp_events], name, default)

  @doc "The storage of the domain a storage resource belongs to."
  @spec storage_for_resource!(module()) :: storage()
  def storage_for_resource!(resource) do
    domain = Ash.Resource.Info.domain(resource)

    storage(domain) ||
      raise ArgumentError,
            "#{inspect(resource)}'s domain #{inspect(domain)} names no `mcp_events` storage"
  end

  @doc "The resources of a storage domain that may emit events (every resource but the storage)."
  @spec source_resources(storage()) :: [module()]
  def source_resources(storage) do
    storage_resources = [storage.subscription, storage.occurrence, storage.delivery]

    storage.domain
    |> Ash.Domain.Info.resources()
    |> Enum.reject(&(&1 in storage_resources))
  end

  @doc """
  Every event of a storage domain, in resource order: each resource's declared events, then its
  default events whose names no declaration took.
  """
  @spec events(module()) :: [Event.t()]
  def events(domain) do
    case storage(domain) do
      nil -> []
      storage -> events_of(storage)
    end
  end

  @doc false
  def events_of(storage) do
    declared =
      for resource <- source_resources(storage),
          AshAi in Spark.extensions(resource),
          event <- Info.declared_events(resource),
          do: resolve(event, resource)

    taken = MapSet.new(declared, & &1.name)

    defaults =
      if storage.defaults? do
        for resource <- source_resources(storage),
            event <- default_events(resource),
            not MapSet.member?(taken, event.name),
            do: event
      else
        []
      end

    Enum.sort_by(
      declared ++ defaults,
      fn event -> Enum.find_index(source_resources(storage), &(&1 == event.resource)) end
    )
  end

  @doc "The events a resource of a storage domain emits."
  @spec resource_events(module(), module()) :: [Event.t()]
  def resource_events(domain, resource) do
    domain |> events() |> Enum.filter(&(&1.resource == resource))
  end

  @doc "The event of a domain with that name."
  @spec event(module(), String.t()) :: Event.t() | nil
  def event(domain, name), do: domain |> events() |> Enum.find(&(&1.name == name))

  @doc "The AshQueue spaces of a resource (none without AshQueue)."
  @spec spaces(module()) :: list()
  def spaces(resource) do
    extensions =
      if is_map(resource),
        do: Spark.Dsl.Extension.get_persisted(resource, :extensions, []),
        else: Spark.extensions(resource)

    if Code.ensure_loaded?(AshQueue.Resource.Info) and AshQueue.Resource in extensions do
      AshQueue.Resource.Info.spaces(resource)
    else
      []
    end
  end

  @doc "The space a `states` event reads: the named one, else the sole one."
  def space_of(resource, space_name) do
    case {spaces(resource), space_name} do
      {[space], nil} -> space
      {spaces, name} when not is_nil(name) -> Enum.find(spaces, &(&1.name == name))
      _ -> nil
    end
  end

  defp resolve(%Event{} = event, resource) do
    attribute =
      case Event.source(event) do
        :states -> space_of(resource, event.space) |> then(&(&1 && &1.attribute))
        _ -> nil
      end

    space =
      case Event.source(event) do
        :states -> space_of(resource, event.space) |> then(&(&1 && &1.name))
        _ -> nil
      end

    %Event{
      event
      | resource: resource,
        attribute: attribute,
        space: space,
        payload: event.payload || public_attribute_names(resource)
    }
  end

  defp default_events(resource) do
    short = resource |> Ash.Resource.Info.short_name() |> to_string()

    for space <- spaces(resource), state <- space.terminal || [] do
      %Event{
        name: "#{short}.#{space.name}.#{state}",
        description:
          "A #{String.replace(short, "_", " ")} entered #{state} in its #{space.name} space.",
        states: [state],
        space: space.name,
        attribute: space.attribute,
        filter: Ash.Resource.Info.primary_key(resource),
        payload: public_attribute_names(resource),
        resource: resource,
        default?: true
      }
    end
  end

  defp public_attribute_names(resource) do
    resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
  end

  ## The listing

  @doc "An `events/list` entry."
  @spec definition(Event.t()) :: map()
  def definition(%Event{} = event) do
    %{"name" => event.name}
    |> put_description(event.description)
    |> Map.merge(%{
      "delivery" => ["webhook"],
      "inputSchema" => input_schema(event),
      "payloadSchema" => payload_schema(event)
    })
  end

  defp put_description(map, nil), do: map
  defp put_description(map, description), do: Map.put(map, "description", description)

  @doc """
  The `inputSchema`: a strict object of the filter fields, each optional, each either one value
  of the attribute's type (an enum attribute: its `enum`) or a non-empty array of them (any of).
  """
  @spec input_schema(Event.t()) :: map()
  def input_schema(%Event{} = event) do
    properties =
      Map.new(event.filter, fn field ->
        scalar = attribute_schema(event.resource, field)

        {to_string(field),
         %{
           "anyOf" => [scalar, %{"type" => "array", "items" => scalar, "minItems" => 1}]
         }}
      end)

    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
  end

  @doc "The `payloadSchema`: an object of the payload fields, all required."
  @spec payload_schema(Event.t()) :: map()
  def payload_schema(%Event{} = event) do
    properties =
      Map.new(event.payload, fn field ->
        attribute = Ash.Resource.Info.attribute(event.resource, field)
        schema = attribute_schema(event.resource, field)

        schema =
          if attribute.allow_nil?,
            do: %{"anyOf" => [schema, %{"type" => "null"}]},
            else: schema

        {to_string(field), schema}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.map(event.payload, &to_string/1),
      "additionalProperties" => false
    }
  end

  defp attribute_schema(resource, field) do
    resource
    |> Ash.Resource.Info.attribute(field)
    |> AshAi.OpenApi.resource_write_attribute_type(resource, :create)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  ## Arguments, facts and matching

  @doc """
  Validates and normalizes `events/subscribe` arguments: only filter fields, each a value the
  attribute accepts (or a non-empty array of them), cast and written back as JSON. An array keeps
  each value once, in the attribute's `one_of`/enum order when it has one, else sorted, so
  equivalent filters share one subscription id.
  """
  @spec normalize_arguments(Event.t(), term()) :: {:ok, map()} | {:error, String.t()}
  def normalize_arguments(%Event{} = event, arguments) when is_map(arguments) do
    allowed = Map.new(event.filter, &{to_string(&1), &1})

    Enum.reduce_while(arguments, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      case Map.fetch(allowed, key) do
        :error ->
          {:halt, {:error, "unknown argument #{inspect(key)}"}}

        {:ok, field} ->
          attribute = Ash.Resource.Info.attribute(event.resource, field)

          case normalize_value(attribute, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
            {:error, message} -> {:halt, {:error, "#{key} #{message}"}}
          end
      end
    end)
  end

  def normalize_arguments(_event, _arguments), do: {:error, "arguments must be an object"}

  defp normalize_value(_attribute, nil), do: {:error, "must not be null"}
  defp normalize_value(_attribute, []), do: {:error, "must not be an empty array"}

  defp normalize_value(attribute, values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_scalar(attribute, value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.uniq() |> order(attribute)}
      error -> error
    end
  end

  defp normalize_value(attribute, value), do: normalize_scalar(attribute, value)

  defp normalize_scalar(attribute, value)
       when is_binary(value) or is_number(value) or is_boolean(value) do
    with {:ok, cast} when not is_nil(cast) <-
           Ash.Type.cast_input(attribute.type, value, attribute.constraints),
         {:ok, cast} when not is_nil(cast) <-
           Ash.Type.apply_constraints(attribute.type, cast, attribute.constraints) do
      {:ok, to_json(cast, attribute)}
    else
      _ -> {:error, "is not a valid #{inspect(attribute.name)} value: #{inspect(value)}"}
    end
  end

  defp normalize_scalar(_attribute, value),
    do: {:error, "must be a string, number or boolean, not #{inspect(value)}"}

  defp order(values, attribute) do
    case enum_values(attribute) do
      nil ->
        Enum.sort_by(values, &AshAi.McpEvents.canonical_json/1)

      known ->
        known = Enum.map(known, &to_string/1)
        Enum.sort_by(values, &(Enum.find_index(known, fn value -> value == &1 end) || 0))
    end
  end

  defp enum_values(attribute) do
    cond do
      is_list(attribute.constraints[:one_of]) ->
        attribute.constraints[:one_of]

      is_atom(attribute.type) and Code.ensure_loaded?(attribute.type) and
          function_exported?(attribute.type, :values, 0) ->
        attribute.type.values()

      true ->
        nil
    end
  end

  @doc "A value as JSON writes it back (what arguments and facts are compared as)."
  def to_json(value, attribute) do
    value
    |> AshAi.Serializer.serialize_value(attribute.type, attribute.constraints, nil)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @doc "The facts of a firing: the filter fields' values, as JSON."
  @spec facts(Event.t(), Ash.Resource.record()) :: map()
  def facts(%Event{} = event, record) do
    Map.new(event.filter, fn field ->
      attribute = Ash.Resource.Info.attribute(event.resource, field)
      {to_string(field), to_json(Map.get(record, field), attribute)}
    end)
  end

  @doc """
  Whether an occurrence's facts satisfy a subscription's arguments: every argument equals its
  fact (an array: the fact is one of them).
  """
  @spec matches?(map(), map()) :: boolean()
  def matches?(arguments, facts) do
    Enum.all?(arguments, fn
      {key, values} when is_list(values) -> Map.get(facts, key) in values
      {key, value} -> Map.get(facts, key) == value
    end)
  end

  @doc "True when the arguments pin every primary key field of the event's resource to one value."
  @spec pins_primary_key?(Event.t(), map()) :: boolean()
  def pins_primary_key?(%Event{} = event, arguments) do
    event.resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.all?(fn field ->
      case Map.get(arguments, to_string(field)) do
        nil -> false
        value when is_list(value) -> false
        _value -> true
      end
    end)
  end

  @doc """
  The event's `data` for a record read as the subscriber, in payload order; `:forbidden` when a
  field policy hides a payload field from them.
  """
  @spec payload(Event.t(), Ash.Resource.record()) :: {:ok, Jason.OrderedObject.t()} | :forbidden
  def payload(%Event{} = event, record) do
    Enum.reduce_while(event.payload, {:ok, []}, fn field, {:ok, acc} ->
      case Map.get(record, field) do
        %Ash.ForbiddenField{} ->
          {:halt, :forbidden}

        value ->
          attribute = Ash.Resource.Info.attribute(event.resource, field)
          {:cont, {:ok, [{to_string(field), to_json(value, attribute)} | acc]}}
      end
    end)
    |> case do
      {:ok, members} -> {:ok, Jason.OrderedObject.new(Enum.reverse(members))}
      :forbidden -> :forbidden
    end
  end

  @doc "The primary key of a record as a JSON object."
  @spec key(module(), Ash.Resource.record()) :: map()
  def key(resource, record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Map.new(fn field ->
      attribute = Ash.Resource.Info.attribute(resource, field)
      {to_string(field), to_json(Map.get(record, field), attribute)}
    end)
  end
end
