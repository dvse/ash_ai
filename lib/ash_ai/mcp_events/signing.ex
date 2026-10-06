# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Signing do
  @moduledoc """
  Standard Webhooks signing (BLENDED-026), as Oberon's `signedHeaders` (`src/webhook.ts`):
  one `v1,<base64 HMAC-SHA256>` signature per active secret over `<id>.<timestamp>.<body>`, keyed
  with the base64-decoded secret after `whsec_`, space-separated.
  """

  @tolerance_seconds 5 * 60

  @doc "The headers of one attempt, signed with every active secret (newest first)."
  @spec headers([String.t()], String.t(), String.t(), String.t(), DateTime.t()) :: %{
          String.t() => String.t()
        }
  def headers(secrets, message_id, body, subscription_id, %DateTime{} = now) do
    timestamp = now |> DateTime.to_unix(:second) |> Integer.to_string()

    %{
      "content-type" => "application/json",
      "webhook-id" => message_id,
      "webhook-timestamp" => timestamp,
      "webhook-signature" =>
        Enum.map_join(secrets, " ", &signature(&1, message_id, timestamp, body)),
      "x-mcp-subscription-id" => subscription_id
    }
  end

  @doc "One `v1,` signature."
  @spec signature(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def signature(secret, message_id, timestamp, body) do
    mac = :crypto.mac(:hmac, :sha256, key(secret), "#{message_id}.#{timestamp}.#{body}")
    "v1," <> Base.encode64(mac)
  end

  @doc """
  Verifies a delivery as a Standard Webhooks receiver does: some `v1` signature in the header
  matches `secret` over the exact body, and the timestamp is within `:tolerance` seconds
  (default 5 min; `false` skips the check) of `:now`.
  """
  @spec verify(String.t(), map(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def verify(body, headers, secret, opts \\ []) do
    headers = Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)
    id = headers["webhook-id"]
    timestamp = headers["webhook-timestamp"]
    signatures = String.split(headers["webhook-signature"] || "", " ", trim: true)

    cond do
      is_nil(id) or is_nil(timestamp) ->
        {:error, "missing required headers"}

      not timestamp_ok?(timestamp, opts) ->
        {:error, "message timestamp too old or too new"}

      Enum.any?(signatures, &secure_equal?(&1, signature(secret, id, timestamp, body))) ->
        :ok

      true ->
        {:error, "no matching signature found"}
    end
  end

  defp timestamp_ok?(timestamp, opts) do
    case Keyword.get(opts, :tolerance, @tolerance_seconds) do
      false ->
        true

      tolerance ->
        now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_unix()

        case Integer.parse(timestamp) do
          {seconds, ""} -> abs(now - seconds) <= tolerance
          _ -> false
        end
    end
  end

  @doc false
  def secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  def secure_equal?(_left, _right), do: false

  defp key("whsec_" <> encoded), do: Base.decode64!(encoded)
  defp key(secret), do: Base.decode64!(secret)
end
