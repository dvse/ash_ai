# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpEvents.EventsTest do
  @moduledoc """
  BLENDED-026: Oberon's `test/events.test.ts` (hyperbob/reference d6d25f2), case by case. Each
  test names the Oberon case it ports. Oberon's in-memory `Subscriptions` becomes the
  subscription storage, its `deliver` loop the AshQueue `collect` and `deliver` edges (run by
  `pump!/0`), its injected `now` the settable clock and its `sleep` the recorded queue backoff.

  Oberon's `thread.turn_ended` filter `thread_id`/`project`/`origin`/`outcomes` is
  `AshAi.Test.McpEvents.Thread`'s `thread_id`/`project`/`origin`/`outcome` (a filter is named
  after its attribute; an array value is "any of", as `outcomes` is).
  """
  use AshAi.Test.McpEventsCase, async: false

  @moduletag :capture_log

  alias AshAi.McpEvents
  alias AshAi.McpEvents.{Catalog, Subscriptions}

  @url_a "https://receiver.example.com/mcp-events/cb_1"
  @turn_ended "thread.turn_ended"
  @outcomes ["completed", "error", "cancelled", "needs_approval"]

  # events.test.ts:48
  test "rejects bad secrets, unknown events, unknown filters, and non-https callbacks" do
    assert {:error, -32_602, message, nil} = subscribe("owner", %{}, secret(1, 16))
    assert message =~ "24–64 bytes"

    assert {:error, -32_602, message, nil} =
             subscribe("owner", %{}, Base.encode64(:binary.copy(<<0>>, 32)))

    assert message =~ "whsec_"

    assert {:error, -32_602, "Unknown event: thread.created", nil} =
             subscribe("owner", %{}, secret(1), %{"name" => "thread.created"})

    assert {:error, -32_602, message, nil} = subscribe("owner", %{"channel_id" => "x"})
    assert message =~ "Invalid arguments"

    assert {:error, -32_015, "Callback URL must use https", %{"reason" => "invalid_url"}} =
             subscribe("owner", %{}, secret(1), %{
               "delivery" => %{
                 "mode" => "webhook",
                 "url" => "http://receiver.example.com/cb",
                 "secret" => secret(1)
               }
             })
  end

  # events.test.ts:57
  test "callback verification failures map to CallbackEndpointError reasons" do
    cases = [
      {fn _ -> {:ok, %{status: 200, body: Jason.encode!(%{challenge: "wrong"})}} end,
       "challenge_failed"},
      {fn _ -> {:ok, %{status: 200, body: "not json"}} end, "challenge_failed"},
      {fn _ -> {:ok, %{status: 500, body: ""}} end, "http_error"},
      {fn _ -> {:error, "Callback timed out"} end, "timeout"},
      # Not in Oberon's list, but its mapping: any other network error is unreachable.
      {fn _ -> {:error, "connect ECONNREFUSED"} end, "unreachable"}
    ]

    for {post, reason} <- cases do
      reset!()
      Receiver.handler(post)

      assert {:error, -32_015, _message, %{"reason" => ^reason}} = subscribe("owner", %{})
      assert subscriptions() == [], "nothing stored after failed verification"
    end
  end

  # events.test.ts:71
  test "subscription identity ignores argument key order; refresh is idempotent and skips re-verification" do
    {:ok, first} = subscribe("owner", Jason.decode!(~s({"thread_id":"T-1","project":"p"})))
    {:ok, again} = subscribe("owner", Jason.decode!(~s({"project":"p","thread_id":"T-1"})))

    assert again["id"] == first["id"]
    assert length(subscriptions()) == 1
    assert length(Receiver.requests()) == 1, "verified once per principal + callback URL"
    assert {first["cursor"], first["truncated"]} == {nil, false}

    {:ok, other} = subscribe("owner", %{"thread_id" => "T-2"})
    assert other["id"] != first["id"]
    {:ok, other_principal} = subscribe("someone-else", %{"thread_id" => "T-1", "project" => "p"})
    assert other_principal["id"] != first["id"]

    # The id is Oberon's derivation: its own `subscriptionId` gives this for principal "owner".
    assert McpEvents.subscription_id("owner", @url_a, @turn_ended, %{
             "project" => "p",
             "thread_id" => "T-1"
           }) == "sub_ff3ec560b75470e4e7d8749468e0a27c"
  end

  # events.test.ts:87
  test "canonicalJson sorts keys at every depth and drops undefined" do
    assert McpEvents.canonical_json(%{b: 1, a: %{d: [%{y: 1, x: 2}], c: nil}}) ==
             ~s({"a":{"d":[{"x":2,"y":1}]},"b":1})
  end

  # events.test.ts:91
  test "grants a bounded TTL" do
    granted = fn ttl ->
      extra = if ttl == :omit, do: %{}, else: %{"ttlMs" => ttl}
      {:ok, %{"refreshBefore" => refresh_before}} = subscribe("owner", %{}, secret(1), extra)
      {:ok, at, 0} = DateTime.from_iso8601(refresh_before)
      DateTime.diff(at, Clock.utc_now(), :millisecond)
    end

    assert granted.(:omit) == McpEvents.default_ttl_ms()
    assert granted.(1_000) == McpEvents.min_ttl_ms()
    assert granted.(2 * 60 * 60 * 1000) == 2 * 60 * 60 * 1000
    assert granted.(30 * 24 * 60 * 60 * 1000) == McpEvents.max_ttl_ms()
    assert granted.(nil) == McpEvents.max_ttl_ms(), "no-expiry requests get a finite grant"
  end

  # events.test.ts:101
  test "matching applies filters and expiry; unsubscribe is idempotent" do
    {:ok, _} = subscribe("owner", %{"thread_id" => "T-1"})
    {:ok, _} = subscribe("owner", %{"project" => "web"})

    assert receivers("T-1", project: "api") == [~s({"thread_id":"T-1"})]
    assert receivers("T-9", project: "web") == [~s({"project":"web"})]
    assert receivers("T-1", project: "web") == [~s({"project":"web"}), ~s({"thread_id":"T-1"})]
    assert receivers("T-9", project: "api") == []

    unsubscribe = %{
      "name" => @turn_ended,
      "arguments" => %{"thread_id" => "T-1"},
      "delivery" => %{"mode" => "webhook", "url" => @url_a}
    }

    assert {:ok, %{}} = Subscriptions.unsubscribe(unsubscribe, opts("owner"))
    assert {:ok, %{}} = Subscriptions.unsubscribe(unsubscribe, opts("owner"))
    assert receivers("T-1", project: "api") == []

    Clock.advance(McpEvents.default_ttl_ms() + 1)
    assert receivers("T-9", project: "web") == [], "expired subscriptions do not match"
  end

  # events.test.ts:119
  test "delivery retries transient failures with the same event ID and stops on 410" do
    Receiver.script([{503, ""}, {:error, "ECONNRESET"}, {200, ""}])
    {:ok, _} = subscribe("owner", %{})
    fire("T-1", project: "p")

    attempts = Receiver.events()
    assert length(attempts) == 3
    [event_id] = attempts |> Enum.map(& &1.headers["webhook-id"]) |> Enum.uniq()
    assert "evt_" <> _ = event_id
    assert retry_delays() == [1_000, 5_000]

    assert %{"eventId" => ^event_id, "name" => @turn_ended, "cursor" => nil, "data" => data} =
             Jason.decode!(List.last(attempts).body)

    assert data["thread_id"] == "T-1"
    assert Enum.uniq(Enum.map(attempts, & &1.body)) |> length() == 1, "the body is frozen"
    for attempt <- attempts, do: assert(signed_with?(secret(1), attempt))
    assert [%{state: :delivered, attempt: 3, last_status: 200}] = deliveries()

    reset!()
    Receiver.script([{410, ""}])
    {:ok, _} = subscribe("owner", %{})
    fire("T-1", project: "p")
    assert length(Receiver.events()) == 1
    assert subscriptions() == [], "410 removes the subscription"
    assert [%{state: :failed, last_status: 410}] = deliveries()

    reset!()
    Receiver.script([{400, ""}])
    {:ok, _} = subscribe("owner", %{})
    fire("T-1", project: "p")
    assert length(Receiver.events()) == 1, "permanent 4xx is not retried"
    assert length(subscriptions()) == 1
    assert [%{state: :failed, last_status: 400}] = deliveries()
    assert retry_delays() == []
  end

  # events.test.ts:147
  test "secret rotation signs with both secrets during the window, then only the new one" do
    {:ok, _} = subscribe("owner", %{}, secret(1))
    {:ok, _} = subscribe("owner", %{}, secret(2))

    [during] = fire("T-1", project: "p")
    assert signed_with?(secret(1), during)
    assert signed_with?(secret(2), during)

    Clock.advance(61 * 60 * 1000)
    [after_window] = fire("T-1", project: "p")
    refute signed_with?(secret(1), after_window)
    assert signed_with?(secret(2), after_window)
  end

  # events.test.ts:167
  test "a subscription without the new arguments keeps the ID it had before they existed" do
    principal = McpEvents.principal(%{id: "owner"})

    before = fn args ->
      digest =
        :crypto.hash(:sha256, ~s(["#{principal}","#{@url_a}","thread.turn_ended",#{args}]))
        |> Base.encode16(case: :lower)

      "sub_" <> binary_part(digest, 0, 32)
    end

    assert {:ok, %{"id" => id}} = subscribe("owner", %{})
    assert id == before.("{}")

    assert {:ok, %{"id" => id}} = subscribe("owner", %{"thread_id" => "T-1", "project" => "p"})
    assert id == before.(~s({"project":"p","thread_id":"T-1"}))

    assert Ash.get!(AshAi.Test.McpEvents.Subscription, before.("{}"), authorize?: false).arguments ==
             %{},
           "no defaults are written into stored arguments"

    # Oberon's `origin: "any"` (its spelled-out default) has no counterpart: `origin` here is the
    # attribute's own vocabulary, and omitting a filter is the only way to say "any".
    assert {:error, -32_602, _, nil} = subscribe("owner", %{"origin" => "any"})
    assert {:ok, %{"id" => oberon}} = subscribe("owner", %{"origin" => "oberon"})
    assert oberon != before.("{}")
  end

  # events.test.ts:180
  test "outcomes are validated and their order does not change the subscription" do
    {:ok, a} = subscribe("owner", %{"outcome" => ["error", "needs_approval"]})
    {:ok, b} = subscribe("owner", %{"outcome" => ["needs_approval", "error", "error"]})
    assert a["id"] == b["id"]

    for bad <- [%{"outcome" => ["idle"]}, %{"outcome" => []}, %{"origin" => "mine"}] do
      assert {:error, -32_602, message, nil} = subscribe("owner", bad)
      assert message =~ "Invalid arguments"
    end

    # Oberon's own id for the same normalized filter (its `outcomes`, principal "owner").
    assert McpEvents.subscription_id("owner", @url_a, @turn_ended, %{
             "outcomes" => ["error", "needs_approval"]
           }) == "sub_3e774e4fb13a2b551688a6ac70012fb3"
  end

  # events.test.ts:190
  test "origin \"oberon\" matches only threads Oberon started; no origin argument matches both" do
    {:ok, _} = subscribe("owner", %{"origin" => "oberon"})
    {:ok, _} = subscribe("owner", %{})

    assert length(fire("T-1", project: "p", origin: :oberon)) == 2
    assert length(fire("T-2", project: "p", origin: :other)) == 1
  end

  # events.test.ts:199
  test "matchesOutcome applies the outcomes filter only when present" do
    assert Catalog.matches?(%{}, %{"outcome" => "error"})
    refute Catalog.matches?(%{"outcome" => ["completed"]}, %{"outcome" => "error"})
    assert Catalog.matches?(%{"outcome" => ["completed", "error"]}, %{"outcome" => "error"})
  end

  # events.test.ts:205
  test "the schemas advertised to clients describe the new argument and payload fields" do
    %{"events" => events} = Subscriptions.list(opts("owner"))
    definition = Enum.find(events, &(&1["name"] == @turn_ended))

    assert definition["delivery"] == ["webhook"]
    input = definition["inputSchema"]
    assert input["additionalProperties"] == false
    assert Map.get(input, "required", []) == []

    assert %{"anyOf" => [%{"enum" => ["oberon", "other"]}, %{"type" => "array"}]} =
             input["properties"]["origin"]

    assert %{"anyOf" => [_one, %{"type" => "array", "items" => %{"enum" => @outcomes}}]} =
             input["properties"]["outcome"]

    payload = definition["payloadSchema"]
    assert "origin" in payload["required"] and "outcome" in payload["required"]
    assert payload["properties"]["origin"]["enum"] == ["oberon", "other"]
  end

  ## Helpers

  defp opts(principal),
    do: [
      events: [AshAi.Test.McpEvents],
      actor: %{id: principal},
      server_url: "https://server.example.com/mcp"
    ]

  defp subscribe(principal, args, secret \\ secret(1), extra \\ %{}) do
    %{
      "name" => @turn_ended,
      "arguments" => args,
      "delivery" => %{"mode" => "webhook", "url" => @url_a, "secret" => secret},
      "cursor" => nil
    }
    |> Map.merge(extra)
    |> Subscriptions.subscribe(opts(principal))
  end

  # A turn ends in a thread with these facts; the queue runs; the event requests it caused.
  defp fire(thread_id, facts) do
    seen = length(Receiver.events())
    end_turn(thread_id, facts)
    pump!()
    Enum.drop(Receiver.events(), seen)
  end

  # Oberon's `ids(facts)`: the arguments of the subscriptions a firing reached, sorted.
  defp receivers(thread_id, facts) do
    arguments = Map.new(subscriptions(), &{&1.id, McpEvents.canonical_json(&1.arguments)})

    thread_id
    |> fire(facts)
    |> Enum.map(&arguments[&1.headers["x-mcp-subscription-id"]])
    |> Enum.sort()
  end
end
