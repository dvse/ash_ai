# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Verifiers.VerifyExposures do
  @moduledoc """
  Verifies domain-level `expose` entries (BLENDED-002).

  Each exposed resource must be registered in the domain `resources` block, each `interface`
  must match a `define` on that resource, and tool names must be unique across the domain's
  `tool` and `interface` entries. Interfaces over non-public actions are skipped at runtime
  rather than rejected here.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  # BLENDED-002: from ash_hyperlang lib/ash_hyperlang/domain.ex:83 (`VerifyExposures.verify/1`)
  @impl true
  def verify(dsl_state) do
    domain = Verifier.get_persisted(dsl_state, :module)
    exposes = AshAi.Info.exposes(dsl_state)

    references_by_resource =
      dsl_state
      |> Verifier.get_entities([:resources])
      |> Map.new(&{&1.resource, &1})

    Enum.reduce_while(exposes, :ok, fn expose, :ok ->
      case verify_expose(domain, expose, references_by_resource) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> verify_unique_names(domain, dsl_state, exposes)
      error -> error
    end
  end

  # BLENDED-002: from ash_hyperlang lib/ash_hyperlang/domain.ex:105
  defp verify_expose(domain, %AshAi.Expose{resource: resource} = expose, references_by_resource) do
    case Map.get(references_by_resource, resource) do
      nil ->
        {:error,
         DslError.exception(
           module: domain,
           path: [:tools, :expose, resource],
           message:
             "expose #{inspect(resource)} must reference a resource registered in the domain resources block"
         )}

      reference ->
        defined_interfaces =
          reference.definitions
          |> Enum.filter(&match?(%Ash.Resource.Interface{}, &1))
          |> MapSet.new(& &1.name)

        case Enum.find(expose.interfaces, &(not MapSet.member?(defined_interfaces, &1.name))) do
          nil ->
            :ok

          interface ->
            {:error,
             DslError.exception(
               module: domain,
               path: [:tools, :expose, resource, :interface, interface.name],
               message:
                 "expose #{inspect(resource)} declares interface #{inspect(interface.name)}, but #{inspect(resource)} has no matching define #{inspect(interface.name)}"
             )}
        end
    end
  end

  # BLENDED-002: tool names stay unique across `tool` and `interface`, mirroring
  # `AshAi.exposed_tools/1`'s runtime `ensure_unique_tool_names!/2`. Only collisions that
  # involve an interface are compile errors here; duplicate `tool` entries keep upstream's
  # runtime error.
  defp verify_unique_names(domain, dsl_state, exposes) do
    tool_names = dsl_state |> AshAi.Info.action_tools() |> Enum.map(& &1.name)

    interface_names =
      Enum.flat_map(exposes, fn expose -> Enum.map(expose.interfaces, & &1.name) end)

    (tool_names ++ interface_names)
    |> Enum.frequencies()
    |> Enum.filter(fn {name, count} -> count > 1 and name in interface_names end)
    |> Enum.map(fn {name, _count} -> name end)
    |> Enum.sort()
    |> case do
      [] ->
        :ok

      names ->
        {:error,
         DslError.exception(
           module: domain,
           path: [:tools],
           message:
             "Duplicate tool names found in #{inspect(domain)}: #{Enum.join(names, ", ")}. Tool names must be unique across `tool` and `expose ... interface` entries."
         )}
    end
  end
end
