# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpEvents.WebhookTest do
  @moduledoc """
  BLENDED-026: Oberon's `test/webhook.test.ts` (hyperbob/reference d6d25f2): the address table,
  the default sender's refusals before connecting, and Standard Webhooks signing.
  """
  use ExUnit.Case, async: true

  alias AshAi.McpEvents.{Address, Signing}

  # webhook.test.ts:6
  test "isPublicAddress blocks private, local, reserved, and mapped addresses" do
    for ip <-
          ~w(10.1.2.3 127.0.0.1 169.254.169.254 172.31.255.255 192.168.1.1 100.64.0.1 0.0.0.0 ::1 :: fd00::1 fe80::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 not-an-ip) do
      refute Address.public?(ip), ip
    end

    for ip <- ~w(8.8.8.8 172.32.0.1 104.18.0.1 2606:4700::1111) do
      assert Address.public?(ip), ip
    end
  end

  test "the rest of Oberon's table: every listed range is refused at its edges, mapped hex forms too" do
    for ip <-
          ~w(0.255.255.255 10.255.255.255 100.127.255.255 127.255.255.255 192.0.0.255 192.0.2.1 198.18.0.1 198.19.255.255 198.51.100.7 203.0.113.9 224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255 64:ff9b::1 100::1 2001:db8::1 fc00::1 ff02::1 ::ffff:7f00:1) do
      refute Address.public?(ip), ip
    end

    for ip <- ~w(100.128.0.1 172.15.255.255 198.20.0.1 192.0.3.1 ::ffff:8.8.8.8 2001:db9::1) do
      assert Address.public?(ip), ip
    end

    assert Address.localhost?("localhost")
    assert Address.localhost?("receiver.localhost")
    refute Address.localhost?("localhost.example.com")
  end

  # webhook.test.ts:13
  test "sendWebhook refuses non-https and private literal callback URLs before connecting" do
    post = &AshAi.McpEvents.Sender.Req.post(%{url: &1, headers: %{}, body: "{}"}, [])

    assert {:error, message} = post.("http://example.com/cb")
    assert message =~ "https"
    assert {:error, message} = post.("https://127.0.0.1/cb")
    assert message =~ "non-public"
    assert {:error, message} = post.("https://[::1]/cb")
    assert message =~ "non-public"
    # Design §7: `localhost` and `*.localhost` are refused as well.
    assert {:error, message} = post.("https://receiver.localhost/cb")
    assert message =~ "non-public"
  end

  test "the default sender refuses a body over 256 KiB before connecting" do
    body = String.duplicate("x", 256 * 1024 + 1)

    assert {:error, "Event body exceeds 256 KiB"} =
             AshAi.McpEvents.Sender.Req.post(
               %{url: "https://8.8.8.8/cb", headers: %{}, body: body},
               []
             )
  end

  # webhook.test.ts:19
  test "signedHeaders produce Standard Webhooks signatures valid for every rotation secret" do
    old_secret = "whsec_" <> Base.encode64(:binary.copy(<<1>>, 32))
    new_secret = "whsec_" <> Base.encode64(:binary.copy(<<2>>, 32))
    body = Jason.encode!(Jason.OrderedObject.new([{"eventId", "evt_1"}, {"data", %{x: "ü"}}]))

    headers =
      Signing.headers([new_secret, old_secret], "evt_1", body, "sub_1", DateTime.utc_now())

    assert headers["webhook-id"] == "evt_1"
    assert headers["x-mcp-subscription-id"] == "sub_1"
    assert headers["content-type"] == "application/json"
    assert length(String.split(headers["webhook-signature"], " ")) == 2

    for secret <- [old_secret, new_secret],
        do: assert(:ok = Signing.verify(body, headers, secret))

    stranger = "whsec_" <> Base.encode64(:binary.copy(<<3>>, 32))
    assert {:error, _} = Signing.verify(body, headers, stranger)

    assert {:error, _} = Signing.verify(body <> " ", headers, new_secret),
           "signature must cover the exact body bytes"
  end

  test "a signature equals the standardwebhooks reference library's" do
    # `new Webhook(secret).sign("evt_1", new Date(1790000000 * 1000), body)` with the npm
    # `standardwebhooks` package Oberon signs with.
    secret = "whsec_" <> Base.encode64(:binary.copy(<<1>>, 32))
    body = ~s({"eventId":"evt_1","data":{"x":"ü"}})

    headers =
      Signing.headers([secret], "evt_1", body, "sub_1", DateTime.from_unix!(1_790_000_000))

    assert headers["webhook-timestamp"] == "1790000000"
    assert headers["webhook-signature"] == "v1,PihoyGn91ub1GWdgfBjHIzIzZ5ciznhLklU8D0Q4sxI="
  end
end
