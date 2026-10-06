# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Sender do
  @moduledoc """
  The transport of MCP Events (BLENDED-026): the only code that reaches a callback URL.

  A domain names its sender in its `mcp_events` section (`sender`, default
  `AshAi.McpEvents.Sender.Req`). The two callbacks are the design's transport binding
  (`verifyMcpEventCallback`, `deliverMcpEvent`):

    * `c:verify_callback/2` posts a verification challenge signed with the new secret and checks
      the echo; it answers `:ok` or `{:error, reason, message}` with a `CallbackEndpointError`
      reason (`"http_error"`, `"challenge_failed"`, `"timeout"`, `"unreachable"`).
    * `c:deliver/2` posts one signed attempt of a frozen body and answers the HTTP status, or
      `{:error, message}` for a network error or timeout.

  `use AshAi.McpEvents.Sender` implements both over one callback, `c:post/2` (an HTTP POST
  answering `{:ok, %{status: status, body: body}}` or `{:error, message}`), with Oberon's
  challenge and Standard Webhooks signing (`AshAi.McpEvents.Signing`). A test sender is then
  only a scripted `post/2`.
  """

  @type verification :: %{
          server_url: String.t() | nil,
          principal: String.t(),
          url: String.t(),
          subscription_id: String.t(),
          secret: String.t()
        }

  @type delivery :: %{
          server_url: String.t() | nil,
          url: String.t(),
          subscription_id: String.t(),
          event_id: String.t(),
          body: String.t(),
          secrets: [String.t()]
        }

  @type request :: %{url: String.t(), headers: %{String.t() => String.t()}, body: String.t()}

  @callback verify_callback(verification(), opts :: keyword()) ::
              :ok | {:error, reason :: String.t(), message :: String.t()}
  @callback deliver(delivery(), opts :: keyword()) ::
              {:ok, status :: non_neg_integer()} | {:error, message :: String.t()}
  @callback post(request(), opts :: keyword()) ::
              {:ok, %{status: non_neg_integer(), body: String.t()}} | {:error, String.t()}

  @optional_callbacks post: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour AshAi.McpEvents.Sender

      @impl AshAi.McpEvents.Sender
      def verify_callback(verification, opts),
        do: AshAi.McpEvents.Sender.verify_with(&post/2, verification, opts)

      @impl AshAi.McpEvents.Sender
      def deliver(delivery, opts),
        do: AshAi.McpEvents.Sender.deliver_with(&post/2, delivery, opts)

      defoverridable verify_callback: 2, deliver: 2
    end
  end

  @doc """
  Oberon's `#verifyCallback` over a `post` function: a `{"type":"verification","challenge":...}`
  body, message id `msg_verification_<hex>`, signed with the new secret alone; a 2xx answer whose
  JSON `challenge` equals the challenge (constant-time) verifies.
  """
  @spec verify_with((request(), keyword() -> term()), verification(), keyword()) ::
          :ok | {:error, String.t(), String.t()}
  def verify_with(post, verification, opts) do
    challenge = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    body =
      Jason.encode!(Jason.OrderedObject.new([{"type", "verification"}, {"challenge", challenge}]))

    message_id =
      "msg_verification_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    headers =
      AshAi.McpEvents.Signing.headers(
        [verification.secret],
        message_id,
        body,
        verification.subscription_id,
        AshAi.McpEvents.Clock.utc_now()
      )

    case post.(%{url: verification.url, headers: headers, body: body}, opts) do
      {:error, message} ->
        message = to_string(message)
        reason = if message =~ ~r/timed out/i, do: "timeout", else: "unreachable"
        {:error, reason, "Callback verification failed: #{message}"}

      {:ok, %{status: status}} when status < 200 or status >= 300 ->
        {:error, "http_error", "Callback verification returned HTTP #{status}"}

      {:ok, %{body: response}} ->
        echoed =
          case Jason.decode(response || "") do
            {:ok, %{"challenge" => echoed}} when is_binary(echoed) -> echoed
            _ -> ""
          end

        if AshAi.McpEvents.Signing.secure_equal?(echoed, challenge) do
          :ok
        else
          {:error, "challenge_failed", "Callback did not echo the verification challenge"}
        end
    end
  end

  @doc "One signed attempt of a frozen body over a `post` function; the message id is the event id."
  @spec deliver_with((request(), keyword() -> term()), delivery(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def deliver_with(post, delivery, opts) do
    headers =
      AshAi.McpEvents.Signing.headers(
        delivery.secrets,
        delivery.event_id,
        delivery.body,
        delivery.subscription_id,
        AshAi.McpEvents.Clock.utc_now()
      )

    case post.(%{url: delivery.url, headers: headers, body: delivery.body}, opts) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, message} -> {:error, to_string(message)}
    end
  end
end
