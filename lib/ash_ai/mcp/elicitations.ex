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

  The store is bounded. A session is kept only when the server exposes a tool with
  `elicit_missing?` to the initializing caller, and only under a session id the server minted (an
  `initialize` that names an existing session id records nothing, so no request can take over
  another session's entry). Each entry belongs to the caller that initialized it (a digest of the
  actor's identity, as `AshAi.Page.session_id/2` makes one): only that caller's calls stream, and
  only that caller's `POST` answers a waiting call. An entry unused for
  `elicitation_session_ttl_ms` (default 24 hours) is forgotten, and at
  `elicitation_session_limit` entries (default 10 000) the expired ones, then the least recently
  used, make room.
  """

  @sessions __MODULE__.Sessions
  @registry __MODULE__.Registry
  @ttl_ms 86_400_000
  @limit 10_000

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

  @doc "The identity a session belongs to: a digest of the actor's identity, nil for none."
  def owner(actor), do: AshAi.Page.session_id(actor, __MODULE__)

  @doc """
  Keeps the form dialect a session's client declared, for the caller `owner` (`nil` forgets the
  session). `opts`: `:elicitation_session_ttl_ms`, `:elicitation_session_limit`.
  """
  def put_session(session_id, dialect, owner, opts \\ [])

  def put_session(session_id, nil, _owner, _opts), do: delete_session(session_id)

  def put_session(session_id, dialect, owner, opts) when is_binary(session_id) do
    now = now()
    make_room(now, ttl(opts), Keyword.get(opts, :elicitation_session_limit, @limit))
    :ets.insert(@sessions, {session_id, dialect, owner, now})
    :ok
  end

  @doc """
  The form dialect of a session's client when the session belongs to `owner` and was used within
  its TTL, or `nil`. A lookup that finds it keeps it alive.
  """
  def session_dialect(session_id, owner, opts \\ [])

  def session_dialect(session_id, owner, opts) when is_binary(session_id) do
    now = now()

    case :ets.lookup(@sessions, session_id) do
      [{^session_id, dialect, ^owner, touched}] ->
        if now - touched <= ttl(opts) do
          :ets.update_element(@sessions, session_id, {4, now})
          dialect
        else
          :ets.delete(@sessions, session_id)
          nil
        end

      _other ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def session_dialect(_session_id, _owner, _opts), do: nil

  @doc "How many sessions are kept (introspection, tests)."
  def session_count do
    :ets.info(@sessions, :size)
  end

  defp ttl(opts), do: Keyword.get(opts, :elicitation_session_ttl_ms, @ttl_ms)
  defp now, do: System.monotonic_time(:millisecond)

  # Below the limit nothing is swept; at it, expired entries go first, then the least recently
  # used until one more fits.
  defp make_room(now, ttl, limit) do
    if :ets.info(@sessions, :size) >= limit do
      :ets.select_delete(@sessions, [
        {{:_, :_, :_, :"$1"}, [{:<, :"$1", now - ttl}], [true]}
      ])

      excess = :ets.info(@sessions, :size) - limit + 1

      if excess > 0 do
        @sessions
        |> :ets.tab2list()
        |> Enum.sort_by(&elem(&1, 3))
        |> Enum.take(excess)
        |> Enum.each(&:ets.delete(@sessions, elem(&1, 0)))
      end
    end
  end

  @doc "Forgets a session."
  def delete_session(session_id) when is_binary(session_id) do
    :ets.delete(@sessions, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete_session(_session_id), do: :ok

  @doc """
  Registers the calling process, a call of `owner`'s, as the one waiting on `request_id` in
  `session_id`.
  """
  def await(session_id, request_id, owner) do
    {:ok, _owner} = Registry.register(@registry, {session_id, request_id}, owner)
    :ok
  end

  @doc "The calling process no longer waits on `request_id`."
  def done(session_id, request_id), do: Registry.unregister(@registry, {session_id, request_id})

  @doc """
  Delivers a client's JSON-RPC response, POSTed by `owner`, to the process waiting on its id in
  `session_id`. `:error` when no call of `owner`'s waits on it.
  """
  def deliver(session_id, owner, %{"id" => request_id} = response) when is_binary(session_id) do
    case Registry.lookup(@registry, {session_id, request_id}) do
      [{pid, ^owner}] ->
        send(pid, {__MODULE__, request_id, response})
        :ok

      _other ->
        :error
    end
  end

  def deliver(_session_id, _owner, _response), do: :error

  @doc "The request ids a session's calls are waiting on (introspection, tests)."
  def pending(session_id) do
    Registry.select(@registry, [{{{session_id, :"$1"}, :_, :_}, [], [:"$1"]}])
  end
end
