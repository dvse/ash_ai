# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Verifiers.VerifyEvents do
  @moduledoc """
  BLENDED-026: refuses bad `mcp_events` declarations.

  On a resource: storage options (they belong to the domain); an event name that is not
  dot-separated lower-case segments; an event with no source or several; `becomes_current?`
  (Ash has no temporal resources); `states` on a resource without an AshQueue space, with an
  ambiguous or unknown `space`, or naming a state outside the space; an `action` that is not a
  create, update or destroy action of the resource; a `filter` or `payload` field that is not a
  public attribute; a `filter` field that is not a scalar.

  On a domain: `event` entities (they belong to resources); incomplete storage; a storage
  resource outside the domain or not written with its `use` macro; a declared event name used
  twice; a resource with an AshQueue space that lacks the `AshAi` extension (its writes could not
  emit its default events).
  """

  use Spark.Dsl.Verifier

  alias AshAi.McpEvent, as: Event
  alias Spark.Dsl.Verifier

  @name_format ~r/^[a-z0-9_]+(\.[a-z0-9_]+)+$/

  @impl true
  def verify(dsl_state) do
    if Map.has_key?(dsl_state, [:attributes]) do
      verify_resource(dsl_state)
    else
      verify_domain(dsl_state)
    end
  end

  ## Resources

  defp verify_resource(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    with :ok <- no_storage_options(dsl_state, module) do
      dsl_state
      |> Verifier.get_entities([:mcp_events])
      |> Enum.find_value(:ok, fn event ->
        case verify_event(dsl_state, event) do
          :ok -> nil
          {:error, message} -> error(module, [:mcp_events, :event, event.name], message)
        end
      end)
    end
  end

  defp no_storage_options(dsl_state, module) do
    [:subscription, :occurrence, :delivery, :sender, :actor_persister]
    |> Enum.find_value(:ok, fn option ->
      if Verifier.get_option(dsl_state, [:mcp_events], option) do
        error(
          module,
          [:mcp_events, option],
          "mcp_events #{option} names event storage, which belongs to the domain's mcp_events section, not a resource's"
        )
      end
    end)
  end

  defp verify_event(dsl_state, %Event{} = event) do
    with :ok <- verify_name(event),
         :ok <- verify_source(dsl_state, event),
         :ok <- verify_fields(dsl_state, event, :filter, event.filter),
         :ok <- verify_scalar_filter(dsl_state, event) do
      verify_fields(dsl_state, event, :payload, event.payload || [])
    end
  end

  defp verify_name(%Event{name: name}) do
    if Regex.match?(@name_format, name) do
      :ok
    else
      {:error,
       "event #{inspect(name)}: a name is dot-separated lower-case segments, like \"ticket.closed\""}
    end
  end

  defp verify_source(dsl_state, %Event{} = event) do
    sources =
      [
        states: event.states not in [nil, []],
        action: not is_nil(event.action),
        becomes_current?: event.becomes_current?
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    case sources do
      [] ->
        {:error,
         "event #{inspect(event.name)} needs exactly one source: states, action or becomes_current?"}

      [_, _ | _] ->
        {:error,
         "event #{inspect(event.name)} has several sources (#{Enum.join(sources, ", ")}); declare exactly one"}

      [:becomes_current?] ->
        {:error,
         "event #{inspect(event.name)}: becomes_current? needs temporal resources, which Ash does not have; use states or action"}

      [:states] ->
        verify_states(dsl_state, event)

      [:action] ->
        verify_action(dsl_state, event)
    end
  end

  defp verify_states(dsl_state, event) do
    spaces = spaces(dsl_state)

    space =
      case {spaces, event.space} do
        {[space], nil} -> {:ok, space}
        {[], _} -> {:error, "states needs an AshQueue space on the resource, and it has none"}
        {_, nil} -> {:error, "the resource has several spaces; name one with `space`"}
        {spaces, name} -> find_space(spaces, name)
      end

    with {:ok, space} <- space,
         [] <- event.states -- (space.states || []) do
      :ok
    else
      {:error, message} ->
        {:error, "event #{inspect(event.name)}: #{message}"}

      unknown ->
        {:error,
         "event #{inspect(event.name)}: #{inspect(unknown)} not in the #{inspect(space_name(space))} space's states"}
    end
  end

  defp space_name({:ok, space}), do: space.name
  defp space_name(_), do: nil

  defp find_space(spaces, name) do
    case Enum.find(spaces, &(&1.name == name)) do
      nil ->
        {:error,
         "space #{inspect(name)} is not a space of the resource (#{inspect(Enum.map(spaces, & &1.name))})"}

      space ->
        {:ok, space}
    end
  end

  defp spaces(dsl_state), do: AshAi.McpEvents.Catalog.spaces(dsl_state)

  defp verify_action(dsl_state, event) do
    case Ash.Resource.Info.action(dsl_state, event.action) do
      %{type: type} when type in [:create, :update, :destroy] ->
        :ok

      %{type: _generic} ->
        {:error,
         "event #{inspect(event.name)}: action #{inspect(event.action)} is a generic action; an event's action is a create, update or destroy action"}

      nil ->
        {:error,
         "event #{inspect(event.name)}: #{inspect(event.action)} is not an action of the resource"}
    end
  end

  defp verify_fields(dsl_state, event, kind, fields) do
    Enum.find_value(fields, :ok, fn field ->
      case Ash.Resource.Info.attribute(dsl_state, field) do
        %{public?: true} ->
          nil

        _ ->
          {:error,
           "event #{inspect(event.name)}: #{kind} field #{inspect(field)} is not a public attribute"}
      end
    end)
  end

  defp verify_scalar_filter(dsl_state, event) do
    Enum.find_value(event.filter, :ok, fn field ->
      attribute = Ash.Resource.Info.attribute(dsl_state, field)

      if scalar?(attribute.type) do
        nil
      else
        {:error,
         "event #{inspect(event.name)}: filter field #{inspect(field)} is not a scalar (#{inspect(attribute.type)})"}
      end
    end)
  end

  defp scalar?({:array, _}), do: false

  defp scalar?(type) do
    type = Ash.Type.get_type(type)

    cond do
      Ash.Type.embedded_type?(type) ->
        false

      type in [Ash.Type.Map, Ash.Type.Struct, Ash.Type.Union, Ash.Type.Keyword, Ash.Type.Tuple] ->
        false

      Ash.Type.NewType.new_type?(type) ->
        scalar?(Ash.Type.NewType.subtype_of(type))

      true ->
        true
    end
  end

  ## Domains

  defp verify_domain(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    with :ok <- no_domain_events(dsl_state, module),
         :ok <- complete_storage(dsl_state, module) do
      if Verifier.get_option(dsl_state, [:mcp_events], :subscription) do
        verify_storage(dsl_state, module)
      else
        :ok
      end
    end
  end

  defp no_domain_events(dsl_state, module) do
    case Verifier.get_entities(dsl_state, [:mcp_events]) do
      [] ->
        :ok

      [event | _] ->
        error(
          module,
          [:mcp_events, :event, event.name],
          "event #{inspect(event.name)} is declared on a domain; declare events on the resource they describe"
        )
    end
  end

  defp complete_storage(dsl_state, module) do
    named =
      Enum.filter(
        [:subscription, :occurrence, :delivery],
        &Verifier.get_option(dsl_state, [:mcp_events], &1)
      )

    case named do
      [] ->
        :ok

      [_, _, _] ->
        :ok

      some ->
        missing = [:subscription, :occurrence, :delivery] -- some

        error(
          module,
          [:mcp_events],
          "mcp_events storage needs subscription, occurrence and delivery; #{Enum.join(missing, ", ")} missing"
        )
    end
  end

  defp verify_storage(dsl_state, module) do
    resources = Ash.Domain.Info.resources(dsl_state)

    storage =
      for role <- [:subscription, :occurrence, :delivery],
          do: {role, Verifier.get_option(dsl_state, [:mcp_events], role)}

    with :ok <- verify_storage_resources(module, resources, storage) do
      sources = resources -- Enum.map(storage, &elem(&1, 1))

      with :ok <- verify_source_extensions(module, sources) do
        verify_unique_names(module, sources)
      end
    end
  end

  defp verify_storage_resources(module, resources, storage) do
    Enum.find_value(storage, :ok, fn {role, resource} ->
      cond do
        resource not in resources ->
          error(
            module,
            [:mcp_events, role],
            "mcp_events #{role} #{inspect(resource)} is not a resource of this domain"
          )

        not (Code.ensure_loaded?(resource) and
               function_exported?(resource, :__mcp_events_role__, 0) and
                 resource.__mcp_events_role__() == role) ->
          error(
            module,
            [:mcp_events, role],
            "mcp_events #{role} #{inspect(resource)} is not written with `use AshAi.McpEvents.#{Macro.camelize(to_string(role))}`"
          )

        true ->
          nil
      end
    end)
  end

  defp verify_source_extensions(module, sources) do
    Enum.find_value(sources, :ok, fn resource ->
      if AshAi.McpEvents.Catalog.spaces(resource) != [] and
           AshAi not in Spark.extensions(resource) do
        error(
          module,
          [:mcp_events],
          "#{inspect(resource)} has an AshQueue space but not the AshAi extension, so its writes cannot emit its default MCP events; add `extensions: [AshAi]`"
        )
      end
    end)
  end

  defp verify_unique_names(module, sources) do
    sources
    |> Enum.filter(&(AshAi in Spark.extensions(&1)))
    |> Enum.flat_map(fn resource ->
      Enum.map(AshAi.McpEvents.Info.declared_events(resource), &{&1.name, resource})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.find_value(:ok, fn
      {_name, [_]} ->
        nil

      {name, owners} ->
        error(
          module,
          [:mcp_events],
          "event #{inspect(name)} is declared by #{Enum.map_join(owners, " and ", &inspect/1)}; event names are unique in a domain"
        )
    end)
  end

  defp error(module, path, message) do
    {:error, Spark.Error.DslError.exception(module: module, path: path, message: message)}
  end
end
