# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.ActorPersister do
  @moduledoc """
  The default persister of a subscriber's actor (BLENDED-026), an `AshQueue.ActorPersister`:
  an Ash record is stored as its resource and primary key and read back by primary key (without
  authorization: the stored reference is the authority, as a session's is). Any other actor is
  refused; a domain whose actors are not records names its own persister (`actor_persister` in its
  `mcp_events` section, or `config :ash_queue, :actor_persister`).
  """

  @doc false
  def store(%resource{} = actor) do
    if Ash.Resource.Info.resource?(resource) do
      key =
        resource
        |> Ash.Resource.Info.primary_key()
        |> Map.new(&{to_string(&1), Map.get(actor, &1)})

      {:ok, %{"resource" => inspect(resource), "primary_key" => key}}
    else
      {:error, "#{inspect(resource)} is not an Ash resource"}
    end
  end

  def store(_actor), do: {:error, "only an Ash record actor can be persisted by default"}

  @doc false
  def lookup(%{"resource" => resource, "primary_key" => key}) do
    resource = Module.safe_concat([resource])

    case Ash.get(resource, key, authorize?: false) do
      {:ok, actor} -> {:ok, actor}
      {:error, error} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  def lookup(_stored), do: {:error, "not a stored actor"}

  @doc "The persister of a storage domain: its own, then AshQueue's configured one, then this."
  @spec for_storage(map()) :: module()
  def for_storage(storage) do
    storage.actor_persister || Application.get_env(:ash_queue, :actor_persister) || __MODULE__
  end

  @doc "Stores an actor with a persister, normalizing the callback's answer."
  @spec store(module(), term()) :: {:ok, map()} | {:error, term()}
  def store(persister, actor) do
    case persister.store(actor) do
      {:ok, stored} when is_map(stored) -> {:ok, stored}
      {:error, error} -> {:error, error}
      stored when is_map(stored) -> {:ok, stored}
    end
  end
end
