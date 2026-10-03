# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Mcp.Elicitations do
  @moduledoc """
  What an initialize-based MCP connection needs to ask its client for missing input
  (BLENDED-023): the form dialect each session's client declared at `initialize`, and the
  pending server-to-client `elicitation/create` requests a streaming `tools/call` waits on.

  A 2026-07-28 request carries its client's capabilities and answers in the request itself, so
  nothing here is used for it. An initialize-based client declares its capabilities once, and
  answers a server request with a separate `POST`, so its session's dialect is kept from
  `initialize` until `DELETE`, and a waiting call is found by its session and request id.
  """

  @sessions __MODULE__.Sessions
  @registry __MODULE__.Registry

  @doc false
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      %{
        id: @sessions,
        start:
          {Agent, :start_link,
           [
             fn -> :ets.new(@sessions, [:named_table, :public, :set, read_concurrency: true]) end,
             [name: @sessions]
           ]}
      }
    ]
  end

  @doc "Keeps the form dialect a session's client declared (`nil` forgets the session)."
  def put_session(session_id, nil), do: delete_session(session_id)

  def put_session(session_id, dialect) when is_binary(session_id) do
    :ets.insert(@sessions, {session_id, dialect})
    :ok
  end

  @doc "The form dialect of a session's client, or `nil`."
  def session_dialect(session_id) when is_binary(session_id) do
    case :ets.lookup(@sessions, session_id) do
      [{^session_id, dialect}] -> dialect
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def session_dialect(_session_id), do: nil

  @doc "Forgets a session."
  def delete_session(session_id) when is_binary(session_id) do
    :ets.delete(@sessions, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete_session(_session_id), do: :ok

  @doc "Registers the calling process as the one waiting on `request_id` in `session_id`."
  def await(session_id, request_id) do
    {:ok, _owner} = Registry.register(@registry, {session_id, request_id}, nil)
    :ok
  end

  @doc "The calling process no longer waits on `request_id`."
  def done(session_id, request_id), do: Registry.unregister(@registry, {session_id, request_id})

  @doc """
  Delivers a client's JSON-RPC response to the process waiting on its id in `session_id`.
  `:error` when no process waits on it.
  """
  def deliver(session_id, %{"id" => request_id} = response) when is_binary(session_id) do
    case Registry.lookup(@registry, {session_id, request_id}) do
      [{pid, _value}] ->
        send(pid, {__MODULE__, request_id, response})
        :ok

      [] ->
        :error
    end
  end

  def deliver(_session_id, _response), do: :error

  @doc "The request ids a session's calls are waiting on (introspection, tests)."
  def pending(session_id) do
    Registry.select(@registry, [{{{session_id, :"$1"}, :_, :_}, [], [:"$1"]}])
  end
end
