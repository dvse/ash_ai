# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Req) do
  defmodule AshAi.McpEvents.Sender.Req do
    @moduledoc """
    The default MCP Events transport (BLENDED-026), over `Req`; Oberon's `sendWebhook`
    (`src/webhook.ts`): HTTPS only; a literal private, loopback, link-local, reserved or mapped
    address (`AshAi.McpEvents.Address.public?/1`), `localhost` and `*.localhost` are refused
    before connecting, as is a host that resolves to any such address; no redirects (a `3xx` is
    an answer, not followed); a 10 s timeout; at most 64 KiB of the response read; a body over
    256 KiB is not sent.

    Oberon checks the resolved address inside the connection's own lookup. Here the host is
    resolved and checked first, then connected to by name, so DNS that changes its answer
    between the two can still reach an address the check refused; a deployment that needs the
    connect-time check supplies its own `c:AshAi.McpEvents.Sender.post/2`.
    """

    use AshAi.McpEvents.Sender

    alias AshAi.McpEvents.Address

    @impl AshAi.McpEvents.Sender
    def post(%{url: url, headers: headers, body: body}, opts) do
      uri = URI.parse(url)
      host = Address.unbracket(uri.host || "")

      cond do
        uri.scheme != "https" ->
          {:error, "Callback URL must use https"}

        host == "" or Address.localhost?(host) ->
          {:error, "Callback URL points to a non-public address"}

        Address.ip_literal?(host) and not Address.public?(host) ->
          {:error, "Callback URL points to a non-public address"}

        byte_size(body) > AshAi.McpEvents.max_event_bytes() ->
          {:error, "Event body exceeds 256 KiB"}

        not Address.ip_literal?(host) and not resolves_publicly?(host) ->
          {:error, "Callback host #{host} resolves to a non-public address"}

        true ->
          send_request(url, headers, body, opts)
      end
    end

    defp resolves_publicly?(host) do
      addresses =
        for family <- [:inet, :inet6],
            {:ok, ips} <- [:inet.getaddrs(String.to_charlist(host), family)],
            ip <- ips,
            do: ip |> :inet.ntoa() |> to_string()

      addresses != [] and Enum.all?(addresses, &Address.public?/1)
    end

    defp send_request(url, headers, body, opts) do
      limit = AshAi.McpEvents.max_response_bytes()
      timeout = AshAi.McpEvents.send_timeout_ms()

      request_opts =
        [
          headers: Map.to_list(headers),
          body: body,
          redirect: false,
          retry: false,
          decode_body: false,
          receive_timeout: timeout,
          connect_options: [timeout: timeout],
          into: fn {:data, data}, {req, resp} ->
            read = resp.body || ""

            if byte_size(read) >= limit do
              {:halt, {req, resp}}
            else
              taken = binary_part(data, 0, min(byte_size(data), limit - byte_size(read)))
              {:cont, {req, %{resp | body: read <> taken}}}
            end
          end
        ]
        |> Keyword.merge(Keyword.get(opts, :req_options, []))

      case Req.post(url, request_opts) do
        {:ok, %Req.Response{status: status, body: response}} ->
          {:ok, %{status: status, body: if(is_binary(response), do: response, else: "")}}

        {:error, %{reason: :timeout}} ->
          {:error, "Callback timed out"}

        {:error, exception} when is_exception(exception) ->
          {:error, Exception.message(exception)}

        {:error, other} ->
          {:error, inspect(other)}
      end
    end
  end
end
