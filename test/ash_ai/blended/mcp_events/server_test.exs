# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpEvents.ServerTest do
  @moduledoc """
  BLENDED-026 over `AshAi.Mcp.Router`: the events part of Oberon's
  `test/app.test.ts:157` ("MCP 2026-07-28: discover advertises events; tools and event
  subscription work end to end", hyperbob/reference d6d25f2), as a ChatGPT-shaped client sees
  it, and the same methods in the initialize-based revisions.

  Not ported, with the reason: that case's Amp tools (`start_thread`, `fetch`, `archive_thread`),
  its OAuth and its instructions text are Oberon's own server, not the events protocol.
  """
  use AshAi.Test.McpEventsCase, async: false

  @moduletag :capture_log

  alias AshAi.Mcp.Router

  @thread "T-01a0f696-61fc-74da-a09c-6725b91a38f8"
  @owner %{id: "owner"}

  # app.test.ts:157
  test "MCP 2026-07-28: discover advertises events; event subscription works end to end" do
    discovered = versioned("server/discover", %{}, @owner)
    assert "2026-07-28" in discovered["result"]["supportedVersions"]
    assert discovered["result"]["capabilities"]["events"] == %{}

    %{"result" => %{"events" => events}} = versioned("events/list", %{}, @owner)
    names = Enum.map(events, & &1["name"])
    assert "thread.turn_ended" in names
    assert Enum.all?(events, &(&1["delivery"] == ["webhook"] and is_map(&1["payloadSchema"])))

    secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

    %{"result" => sub} =
      versioned(
        "events/subscribe",
        %{
          "name" => "thread.turn_ended",
          "arguments" => %{"thread_id" => @thread},
          "delivery" => %{
            "mode" => "webhook",
            "url" => "https://receiver.example.com/cb_1",
            "secret" => secret
          },
          "cursor" => nil
        },
        @owner
      )

    assert "sub_" <> _ = sub["id"]
    assert is_binary(sub["refreshBefore"])
    assert sub["cursor"] == nil
    assert sub["truncated"] == false
    assert sub["resultType"] == "complete"

    %{"error" => error} =
      versioned(
        "events/subscribe",
        %{
          "name" => "thread.turn_ended",
          "arguments" => %{},
          "delivery" => %{
            "mode" => "webhook",
            "url" => "https://receiver.example.com/cb_1",
            "secret" => "whsec_c2hvcnQ="
          }
        },
        @owner
      )

    assert error["code"] == -32_602
    assert error["message"] =~ "24–64 bytes"

    # A turn ends in a thread that does not match the filter: nothing is delivered.
    before = length(Receiver.requests())
    end_turn("T-00000000-0000-0000-0000-000000000000")
    pump!()
    assert length(Receiver.requests()) == before

    Clock.set(~U[2030-10-01 12:05:00.000000Z])

    end_turn(@thread,
      title: "Fix the bug",
      final_message: "Fixed the bug and pushed.",
      origin: :oberon
    )

    pump!()

    delivered = List.last(Receiver.requests())
    assert delivered.headers["x-mcp-subscription-id"] == sub["id"]

    assert :ok =
             AshAi.McpEvents.Signing.verify(delivered.body, delivered.headers, secret,
               tolerance: false
             )

    event = Jason.decode!(delivered.body)
    assert event["name"] == "thread.turn_ended"
    assert event["eventId"] == delivered.headers["webhook-id"]
    assert event["timestamp"] == "2030-10-01T12:05:00.000Z"

    assert event["data"] == %{
             "thread_id" => @thread,
             "title" => "Fix the bug",
             "url" => "https://ampcode.com/threads/#{@thread}",
             "project" => "amp-mcp",
             "origin" => "oberon",
             "agent_state" => "idle",
             "outcome" => "completed",
             "final_message" => "Fixed the bug and pushed.",
             "final_message_truncated" => false
           }

    assert %{"result" => %{"resultType" => "complete"}} =
             versioned(
               "events/unsubscribe",
               %{
                 "name" => "thread.turn_ended",
                 "arguments" => %{"thread_id" => @thread},
                 "delivery" => %{
                   "mode" => "webhook",
                   "url" => "https://receiver.example.com/cb_1"
                 }
               },
               @owner
             )

    assert subscriptions() == []
    seen = length(Receiver.requests())
    end_turn(@thread)
    pump!()
    assert length(Receiver.requests()) == seen
  end

  test "initialize-based revisions: the capability and the same three methods" do
    %{"result" => %{"capabilities" => capabilities}} =
      rpc("initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}, @owner)

    assert capabilities["events"] == %{}

    %{"result" => %{"events" => events}} = rpc("events/list", nil, @owner)
    assert "ticket.flow.closed" in Enum.map(events, & &1["name"])

    params = %{
      "name" => "ticket.created",
      "arguments" => %{"project" => "web"},
      "delivery" => %{
        "mode" => "webhook",
        "url" => "https://r.example.com/cb",
        "secret" => secret(4)
      }
    }

    %{"result" => %{"id" => "sub_" <> _, "cursor" => nil, "truncated" => false}} =
      rpc("events/subscribe", params, @owner)

    %{"error" => %{"code" => -32_015, "data" => %{"reason" => "invalid_url"}}} =
      rpc(
        "events/subscribe",
        put_in(params, ["delivery", "url"], "http://r.example.com/cb"),
        @owner
      )

    %{"error" => %{"code" => -32_602, "message" => "Only webhook delivery is supported"}} =
      rpc("events/subscribe", put_in(params, ["delivery", "mode"], "sse"), @owner)

    assert %{"result" => result} =
             rpc(
               "events/unsubscribe",
               Map.update!(params, "delivery", &Map.delete(&1, "secret")),
               @owner
             )

    assert result == %{}
  end

  test "an anonymous caller may list but not subscribe" do
    %{"result" => %{"events" => [_ | _]}} = rpc("events/list", nil, nil)

    %{"error" => %{"code" => -32_600, "message" => message}} =
      rpc(
        "events/subscribe",
        %{
          "name" => "ticket.created",
          "arguments" => %{},
          "delivery" => %{
            "mode" => "webhook",
            "url" => "https://r.example.com/cb",
            "secret" => secret(4)
          }
        },
        nil
      )

    assert message =~ "authenticated"
    assert Receiver.requests() == [], "no verification for an anonymous caller"
  end

  test "a server serving no event has no capability and does not know the methods" do
    %{"result" => %{"capabilities" => capabilities}} =
      rpc("initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}, @owner,
        events: false
      )

    refute Map.has_key?(capabilities, "events")

    assert %{"error" => %{"code" => -32_601}} = rpc("events/list", nil, @owner, events: false)

    discovered = versioned("server/discover", %{}, @owner, events: false)
    refute Map.has_key?(discovered["result"]["capabilities"], "events")

    assert %{"error" => %{"code" => -32_601}} =
             versioned("events/list", %{}, @owner, events: false)
  end

  defp router_opts(extra) do
    Router.init(
      Keyword.merge([otp_app: :ash_ai, tools: [], events: [AshAi.Test.McpEvents]], extra)
    )
  end

  defp rpc(method, params, actor, extra \\ []) do
    message =
      %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
      |> then(&if(params, do: Map.put(&1, "params", params), else: &1))

    actor
    |> conn(message, %{})
    |> Router.call(router_opts(extra))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp versioned(method, params, actor, extra \\ []) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "chatgpt", "version" => "1"}
    }

    actor
    |> conn(
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => Map.put(params, "_meta", meta)
      },
      %{"mcp-protocol-version" => "2026-07-28", "mcp-method" => method}
    )
    |> Router.call(router_opts(extra))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp conn(actor, message, headers) do
    Plug.Test.conn(:post, "/", message)
    |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
    |> then(
      &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    )
    |> then(&if(actor, do: Ash.PlugHelpers.set_actor(&1, actor), else: &1))
  end
end
