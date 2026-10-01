# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpActions.Run.Mcp do
  @moduledoc """
  Implementation backing the synthesized `:mcp` action (BLENDED-014).

  Builds the request as an in-memory `Plug.Conn` (`AshAi.McpActions.Conn`),
  runs `AshAi.Mcp.Server.handle_post/4` with the section's server options
  and the action's actor, tenant and context, and returns the response the
  server sent.
  """

  use Ash.Resource.Actions.Implementation

  alias AshAi.Mcp.Server
  alias AshAi.McpActions.{Conn, Info}

  @impl true
  def run(input, _opts, context) do
    request = input.arguments.request
    conn = Conn.build(field(request, :headers))

    opts =
      input.resource
      |> Info.server_options()
      |> Keyword.merge(
        actor: context.actor,
        tenant: context.tenant,
        context: Map.get(context, :source_context) || %{}
      )
      |> put_server_url(field(request, :server_url))
      |> put_files(field(request, :files))

    conn = Server.handle_post(conn, field(request, :body), session_id(conn), opts)

    {:ok, Conn.response(conn)}
  end

  defp put_server_url(opts, nil), do: opts
  defp put_server_url(opts, server_url), do: Keyword.put(opts, :server_url, server_url)

  # BLENDED-018: file bytes the host fetched for this request reach the tools' actions as
  # `context.mcp_files`. They are the caller's request data, never authority.
  defp put_files(opts, files) when is_list(files),
    do: Keyword.update(opts, :context, %{mcp_files: files}, &Map.put(&1, :mcp_files, files))

  defp put_files(opts, _files), do: opts

  # As `AshAi.Mcp.Router.get_session_id/1`
  defp session_id(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-session-id") do
      [session_id | _] -> session_id
      [] -> nil
    end
  end

  defp field(request, key), do: Map.get(request, key, Map.get(request, to_string(key)))
end
