# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpActions.Conn do
  @moduledoc """
  An in-memory `Plug.Conn` for the synthesized `:mcp` action (BLENDED-014).

  `AshAi.Mcp.Server` reads its request from a conn and sends its response to
  it. This adapter keeps the response on the conn instead of a socket:
  `send_resp` stores the body, and a chunked response (`subscriptions/listen`)
  accumulates its chunks. The conn has no owner process, so nothing is sent
  to the caller's mailbox.
  """

  @behaviour Plug.Conn.Adapter

  @doc "A `POST /` conn carrying `headers` (a map of lower-case names to a string or a list)."
  @spec build(map() | nil) :: Plug.Conn.t()
  def build(headers) do
    %Plug.Conn{
      adapter: {__MODULE__, ""},
      owner: nil,
      method: "POST",
      scheme: :https,
      host: "localhost",
      port: 443,
      request_path: "/",
      path_info: [],
      req_headers: req_headers(headers)
    }
  end

  @doc "The response the server sent: `%{status:, headers:, body:}`."
  @spec response(Plug.Conn.t()) :: %{status: integer(), headers: map(), body: String.t()}
  def response(%Plug.Conn{} = conn) do
    %{status: conn.status, headers: Map.new(conn.resp_headers), body: conn.resp_body || ""}
  end

  defp req_headers(headers) when is_map(headers) do
    headers
    |> Enum.sort()
    |> Enum.flat_map(fn {name, value} ->
      name = name |> to_string() |> String.downcase()
      value |> List.wrap() |> Enum.map(&{name, to_string(&1)})
    end)
  end

  defp req_headers(_headers), do: []

  @impl true
  def send_resp(_payload, _status, _headers, body) do
    body = IO.iodata_to_binary(body)
    {:ok, body, body}
  end

  @impl true
  def send_chunked(_payload, _status, _headers), do: {:ok, "", ""}

  @impl true
  def chunk(payload, chunk) do
    body = payload <> IO.iodata_to_binary(chunk)
    {:ok, body, body}
  end

  @impl true
  def send_file(_payload, _status, _headers, _path, _offset, _length),
    do: raise(ArgumentError, "the MCP action does not send files")

  @impl true
  def read_req_body(payload, _opts), do: {:ok, "", payload}

  @impl true
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl true
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}

  @impl true
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl true
  def get_peer_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

  @impl true
  def get_sock_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0}

  @impl true
  def get_ssl_data(_payload), do: nil

  @impl true
  def get_http_protocol(_payload), do: :"HTTP/1.1"
end
