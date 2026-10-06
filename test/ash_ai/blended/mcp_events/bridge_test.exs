# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpEvents.BridgeTest do
  @moduledoc """
  BLENDED-026: the subscription-touching cases of Oberon's `test/bridge.test.ts`
  (hyperbob/reference d6d25f2). Oberon's `publishTurnEnded` (match, read the thread, deliver) is
  here emission in the thread's own write plus the subscription's `collect` edge; its
  `RecentTurns`/`catchUpSubscription` is the new subscription's cursor starting 2 min back when
  its arguments pin the thread.

  Not ported, with the reason: `bridge.test.ts:31` ("waits for the thread export to settle")
  and `:145` ("threads stopped in error... settle") test Amp's export settling; a record is read
  after its own commit, so there is nothing to settle.
  """
  use AshAi.Test.McpEventsCase, async: false

  @moduletag :capture_log

  alias AshAi.McpEvents.Subscriptions

  @id "T-01a0f696-61fc-74da-a09c-6725b91a38f8"
  @other "T-01a0f696-0000-7000-8000-000000000001"

  # bridge.test.ts:43
  test "event IDs are stable per turn and differ across turns" do
    {:ok, _} = subscribe(%{"thread_id" => @id})

    end_turn(@id, final_message: "OK2")
    pump!()
    # A second sweep, and a stale wake of the edge, find nothing new: no second delivery.
    pump!()
    [subscription] = subscriptions()
    _ = AshQueue.Test.wake(subscription, :collect)
    pump!()

    end_turn(@id, final_message: "OK3")
    pump!()

    [a, c] = Enum.map(Receiver.event_bodies(), & &1["eventId"])
    assert a != c, "a new turn is a new event"
    assert length(deliveries()) == 2

    # A redelivered attempt keeps its event id (events_test: the 503/ECONNRESET/200 case).
  end

  # bridge.test.ts:53
  test "does not read the thread when nobody is subscribed" do
    end_turn(@id)
    pump!()

    assert AshAi.Test.McpEvents.Reads.count() == 0

    assert [%{name: "thread.turn_ended"}] =
             Ash.read!(AshAi.Test.McpEvents.Occurrence, authorize?: false)

    assert Receiver.requests() == []
  end

  # bridge.test.ts:79
  test "an origin-filtered subscription fires for Oberon-started threads only, including after a restart" do
    # Oberon records origins in a file a restarted process reads; here `origin` is the thread's
    # own attribute, durable with it.
    Ash.create!(Thread, %{thread_id: @id, origin: :oberon}, authorize?: false)
    {:ok, _} = subscribe(%{"origin" => "oberon"})

    end_turn(@other)
    pump!()
    assert Receiver.event_bodies() == [], "a thread Oberon did not start does not fire"

    end_turn(@id)
    pump!()
    assert [%{"data" => %{"origin" => "oberon"}}] = Receiver.event_bodies()
  end

  # bridge.test.ts:99
  test "subscriptions without origin still receive every thread, labelled by origin" do
    Ash.create!(Thread, %{thread_id: @id, origin: :oberon}, authorize?: false)
    {:ok, _} = subscribe(%{})

    end_turn(@id)
    pump!()
    end_turn(@other)
    pump!()

    assert Enum.map(Receiver.event_bodies(), &[&1["data"]["thread_id"], &1["data"]["origin"]]) ==
             [[@id, "oberon"], [@other, "other"]]
  end

  # bridge.test.ts:109 (the filter; the agent-state -> outcome table is Amp's own and not ported)
  test "outcome follows the settled agent state and the outcomes filter drops the rest" do
    {:ok, _} = subscribe(%{"outcome" => ["error", "needs_approval"]})

    for {state, outcome} <- [
          {"idle", :completed},
          {"error", :error},
          {"cancelled", :cancelled},
          {"awaiting_approval", :needs_approval}
        ] do
      end_turn(@id, agent_state: state, outcome: outcome)
      pump!()
    end

    assert Enum.map(Receiver.event_bodies(), &{&1["data"]["outcome"], &1["data"]["agent_state"]}) ==
             [{"error", "error"}, {"needs_approval", "awaiting_approval"}],
           "the raw state stays available"
  end

  ## Catch-up: a turn that ends before (or while) the client subscribes

  # bridge.test.ts:195
  test "a thread_id subscription created just after its turn ended still gets that turn" do
    Clock.set(~U[2030-10-05 19:18:58.000000Z])
    end_turn(@id, final_message: "Soft rain taps the leaves")
    pump!()
    assert Receiver.event_bodies() == []

    Clock.advance(500)
    {:ok, sub} = subscribe(%{"thread_id" => @id}, "https://connectors.example.com/cb")
    pump!()

    assert [event] = Receiver.events()
    assert event.headers["x-mcp-subscription-id"] == sub["id"]
    body = Jason.decode!(event.body)
    assert body["data"]["final_message"] == "Soft rain taps the leaves"

    assert body["timestamp"] == "2030-10-05T19:18:58.000Z",
           "stamped with when the turn ended, not when it was caught up"
  end

  # bridge.test.ts:209
  test "catch-up honours the subscription filters" do
    end_turn(@id)
    pump!()
    {:ok, _} = subscribe(%{"thread_id" => @id, "origin" => "oberon"})
    pump!()
    assert Receiver.event_bodies() == [], "thread was not started through Oberon"

    # Oberon re-reads the origin at catch-up; here the filter matches the facts the turn fired
    # with, so the matching case is a turn that ended as an Oberon thread.
    Ash.create!(Thread, %{thread_id: @other, origin: :oberon}, authorize?: false)
    end_turn(@other)
    pump!()

    {:ok, _} =
      subscribe(
        %{"thread_id" => @other, "origin" => "oberon"},
        "https://connectors.example.com/cb2"
      )

    pump!()
    assert length(Receiver.event_bodies()) == 1
  end

  # bridge.test.ts:219
  test "no catch-up for old turns, other threads, or subscriptions without thread_id" do
    end_turn(@id)
    pump!()

    Clock.advance(121_000)
    {:ok, _} = subscribe(%{"thread_id" => @id})

    {:ok, _} =
      subscribe(
        %{"thread_id" => "T-00000000-0000-0000-0000-000000000000"},
        "https://connectors.example.com/other"
      )

    Clock.advance(-121_000)
    {:ok, _} = subscribe(%{"project" => "amp-mcp"}, "https://connectors.example.com/project")
    {:ok, _} = subscribe(%{}, "https://connectors.example.com/all")
    pump!()

    assert Receiver.event_bodies() == []
  end

  # bridge.test.ts:231
  test "catch-up goes only to the new subscription, not to existing ones that already had their chance" do
    {:ok, early} = subscribe(%{"project" => "amp-mcp"}, "https://connectors.example.com/early")
    end_turn(@id)
    pump!()
    assert Enum.map(Receiver.events(), & &1.headers["x-mcp-subscription-id"]) == [early["id"]]

    {:ok, late} = subscribe(%{"thread_id" => @id}, "https://connectors.example.com/late")
    pump!()

    assert Enum.map(Receiver.events(), & &1.headers["x-mcp-subscription-id"]) ==
             [early["id"], late["id"]]

    [first, second] = Receiver.event_bodies()
    assert first["eventId"] == second["eventId"], "same turn, same event ID"
  end

  defp subscribe(args, url \\ "https://r.example.com/cb") do
    Subscriptions.subscribe(
      %{
        "name" => "thread.turn_ended",
        "arguments" => args,
        "delivery" => %{"mode" => "webhook", "url" => url, "secret" => secret(9)}
      },
      events: [AshAi.Test.McpEvents],
      actor: %{id: "owner"}
    )
  end
end
