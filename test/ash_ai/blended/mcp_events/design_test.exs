# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpEvents.DesignTest do
  @moduledoc """
  BLENDED-026 beyond Oberon's cases: the declarations and their refusals, default events,
  emission, reading as the subscriber, the AshQueue edges (expiry, pruning, exhaustion, the
  sweep alone), the body cap and the delivery outcomes Oberon's tests do not reach
  (hyperbob-cloud `reports/mcp-events-design-2026-10-06.md` §2-§6).
  """
  use AshAi.Test.McpEventsCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureIO

  alias AshAi.McpEvents
  alias AshAi.McpEvents.{Catalog, Subscriptions}
  alias AshAi.McpEvents.Verifiers.VerifyEvents
  alias AshAi.Test.McpEvents.{Delivery, Occurrence, Subscription}

  describe "the catalog" do
    test "declared events, defaults per terminal state, a declaration replacing a default" do
      events = Map.new(Catalog.events(AshAi.Test.McpEvents), &{&1.name, &1})

      assert Map.keys(events) |> Enum.sort() ==
               [
                 "thread.turn_ended",
                 "ticket.created",
                 "ticket.flow.closed",
                 "ticket.flow.rejected"
               ]

      closed = events["ticket.flow.closed"]
      assert closed.default?
      assert closed.states == [:closed]
      assert closed.filter == [:id]
      assert closed.payload == [:id, :title, :project, :state]
      assert closed.description == "A ticket entered closed in its flow space."

      rejected = events["ticket.flow.rejected"]
      refute rejected.default?
      assert rejected.description == "A ticket was rejected."
      assert rejected.payload == [:id, :title]

      assert events["ticket.created"].action == :create
      # The thread's space has no terminal state (turns repeat), so it has no default event.
      refute Enum.any?(Map.keys(events), &String.starts_with?(&1, "thread.turn."))
    end

    test "the default event's schemas: the primary key as filter, the public attributes as payload" do
      %{"events" => events} = Subscriptions.list(events: [AshAi.Test.McpEvents])
      closed = Enum.find(events, &(&1["name"] == "ticket.flow.closed"))

      assert Map.keys(closed["inputSchema"]["properties"]) == ["id"]
      assert closed["payloadSchema"]["required"] == ["id", "title", "project", "state"]
      assert closed["payloadSchema"]["additionalProperties"] == false

      assert closed["payloadSchema"]["properties"]["title"] == %{
               "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]
             }
    end

    test "the storage resources emit nothing and are no event sources" do
      sources = Catalog.source_resources(Catalog.storage(AshAi.Test.McpEvents))
      assert AshAi.Test.McpEvents.Thread in sources
      refute Subscription in sources
      refute Delivery in sources
    end
  end

  describe "emission" do
    test "an occurrence per firing, in the writer's own action: create, the space entering a state" do
      ticket = Ash.create!(Ticket, %{id: "K-1", title: "Fix", project: "web"})
      ticket |> Ash.update!(%{title: "Fix it"})

      ticket
      |> Ash.Changeset.for_update(:close, %{})
      |> Ash.update!()

      occurrences = Ash.read!(Occurrence, authorize?: false) |> Enum.sort_by(& &1.sort_key)
      assert Enum.map(occurrences, & &1.name) == ["ticket.created", "ticket.flow.closed"]

      [created, closed] = occurrences
      assert created.facts == %{"project" => "web"}
      assert closed.facts == %{"id" => "K-1"}
      assert closed.key == %{"id" => "K-1"}
      assert closed.resource == "AshAi.Test.McpEvents.Ticket"
      assert "evt_" <> hex = closed.id
      assert byte_size(hex) == 32
      assert closed.sort_key == McpEvents.sort_key(closed.occurred_at, closed.id)
      assert DateTime.diff(closed.prune_at, closed.occurred_at, :millisecond) == 86_400_000
      assert created.id < closed.id, "event ids are time-ordered"
    end

    test "a default event is delivered to a subscription pinning the record" do
      {:ok, sub} = subscribe("ticket.flow.closed", %{"id" => "K-1"})
      ticket = Ash.create!(Ticket, %{id: "K-1", title: "Fix", project: "web"})
      Ash.create!(Ticket, %{id: "K-2", title: "Other", project: "web"}) |> close!()
      close!(ticket)
      pump!()

      assert [event] = Receiver.events()
      assert event.headers["x-mcp-subscription-id"] == sub["id"]

      assert Jason.decode!(event.body)["data"] == %{
               "id" => "K-1",
               "title" => "Fix",
               "project" => "web",
               "state" => "closed"
             }

      # Payload keys keep the declaration's order in the frozen body.
      assert event.body =~ ~s("data":{"id":"K-1","title":"Fix","project":"web","state":"closed"})
    end
  end

  describe "reading as the subscriber" do
    test "a record the subscriber cannot read is not delivered at all" do
      Ash.create!(Thread, %{thread_id: "T-1", owner: "alice"}, authorize?: false)
      {:ok, _} = subscribe("thread.turn_ended", %{}, "owner")
      {:ok, alice} = subscribe("thread.turn_ended", %{}, "alice", "https://alice.example.com/cb")

      end_turn("T-1")
      pump!()

      assert [event] = Receiver.events()
      assert event.headers["x-mcp-subscription-id"] == alice["id"]
      assert length(deliveries()) == 1
      assert AshAi.Test.McpEvents.Reads.count() == 2, "both subscribers' reads ran, as themselves"
    end
  end

  describe "the AshQueue edges" do
    test "expire: a subscription past expires_at leaves the active state on the sweep, then is pruned" do
      reset!(DateTime.add(DateTime.utc_now(), -2 * 86_400, :second))
      {:ok, _} = subscribe("thread.turn_ended", %{})
      [subscription] = subscriptions()
      AshQueue.Test.assert_would_schedule(subscription, :expire)

      subscription
      |> Ash.Changeset.for_update(:expire, %{})
      |> Ash.update!(authorize?: false)
      |> AshQueue.Test.assert_state(:expired)

      pump!()
      assert subscriptions() == [], "expired rows are pruned"
    end

    test "occurrences are pruned 24 h after they occurred" do
      reset!(DateTime.add(DateTime.utc_now(), -2 * 86_400, :second))
      end_turn("T-1")
      assert [_] = Ash.read!(Occurrence, authorize?: false)
      pump!()
      assert Ash.read!(Occurrence, authorize?: false) == []
    end

    test "a delivery gives up after five attempts, 1 s, 5 s, 30 s and 2 min apart" do
      Receiver.script(List.duplicate({503, ""}, 6))
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1")
      pump!()

      assert length(Receiver.events()) == 5
      assert retry_delays() == [1_000, 5_000, 30_000, 120_000]
      assert [%{state: :failed, attempt: 5, last_error: last_error}] = deliveries()
      assert last_error =~ "HTTP 503"
    end

    test "408 and 429 are retried; 413 is not" do
      Receiver.script([{408, ""}, {429, ""}, {200, ""}])
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1")
      pump!()
      assert length(Receiver.events()) == 3
      assert [%{state: :delivered}] = deliveries()

      reset!()
      Receiver.script([{413, ""}])
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1")
      pump!()
      assert length(Receiver.events()) == 1
      assert [%{state: :failed, last_status: 413}] = deliveries()
    end

    test "a subscription that ends between attempts fails the delivery without a request" do
      Receiver.script([{503, ""}])
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1")
      # One attempt, then the subscription expires before the retry.
      pump!(1)
      assert length(Receiver.events()) == 1

      Clock.advance(McpEvents.default_ttl_ms())
      pump!()

      assert length(Receiver.events()) == 1
      assert [%{state: :failed, last_error: "subscription ended"}] = deliveries()
    end

    test "with reactive wakes suppressed, the sweep alone delivers" do
      Application.put_env(:ash_queue, :suppress_reactive_enqueue, true)
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1")
      assert live_jobs() == [], "no wake was enqueued"

      pump!()
      assert [%{"name" => "thread.turn_ended"}] = Receiver.event_bodies()
    end

    test "a refresh keeps the cursor and never redelivers" do
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1")
      pump!()
      [before] = subscriptions()

      Clock.advance(1_000)
      {:ok, _} = subscribe("thread.turn_ended", %{})
      pump!()

      [refreshed] = subscriptions()
      assert refreshed.cursor == before.cursor
      assert DateTime.compare(refreshed.expires_at, before.expires_at) == :gt
      assert length(Receiver.events()) == 1
    end

    test "an event body over 256 KiB is not delivered, and the cursor moves on" do
      {:ok, _} = subscribe("thread.turn_ended", %{})
      end_turn("T-1", final_message: String.duplicate("x", 300 * 1024))
      pump!()

      assert deliveries() == []
      assert Receiver.events() == []
      [subscription] = subscriptions()
      [occurrence] = Ash.read!(Occurrence, authorize?: false)
      assert subscription.cursor == occurrence.sort_key
    end
  end

  describe "refusals" do
    test "becomes_current? is refused: Ash has no temporal resources" do
      assert resource_refusal(~s(event "x.current" do\n becomes_current? true\n end)) =~
               "becomes_current? needs temporal resources"
    end

    test "an event needs exactly one source" do
      assert resource_refusal(~s(event "x.none" do\n filter [:title]\n end)) =~
               "needs exactly one source"

      assert resource_refusal(~s(event "x.two" do\n states [:closed]\n action :create\n end)) =~
               "has several sources"
    end

    test "states must be the space's; the resource must have a space" do
      assert resource_refusal(~s(event "x.y" do\n states [:gone]\n end)) =~
               "[:gone] not in the :flow space's states"

      assert resource_refusal(~s(event "x.y" do\n states [:closed]\n space :other\n end)) =~
               "space :other is not a space of the resource"

      assert resource_refusal(~s(event "x.y" do\n states [:closed]\n end), queue?: false) =~
               "states needs an AshQueue space"
    end

    test "an action source is a create, update or destroy action of the resource" do
      assert resource_refusal(~s(event "x.y" do\n action :ping\n end)) =~
               "action :ping is a generic action"

      assert resource_refusal(~s(event "x.y" do\n action :nope\n end)) =~
               ":nope is not an action of the resource"
    end

    test "filter and payload fields are public attributes; filters are scalars" do
      assert resource_refusal(~s(event "x.y" do\n action :create\n filter [:secret]\n end)) =~
               "filter field :secret is not a public attribute"

      assert resource_refusal(~s(event "x.y" do\n action :create\n payload [:secret]\n end)) =~
               "payload field :secret is not a public attribute"

      assert resource_refusal(~s(event "x.y" do\n action :create\n filter [:meta]\n end)) =~
               "filter field :meta is not a scalar"
    end

    test "an event name is dot-separated lower-case segments" do
      assert resource_refusal(~s(event "Ticket Closed" do\n action :create\n end)) =~
               "a name is dot-separated lower-case segments"
    end

    test "storage belongs to the domain, events to resources" do
      assert resource_refusal("subscription AshAi.Test.McpEvents.Subscription") =~
               "belongs to the domain's mcp_events section"

      assert domain_refusal(~s(event "x.y" do\n action :create\n end)) =~
               "is declared on a domain"

      assert domain_refusal("subscription AshAi.Test.McpEvents.Subscription") =~
               "occurrence, delivery missing"
    end

    test "a storage domain's resources with a space need the AshAi extension" do
      assert domain_refusal(
               """
               subscription AshAi.Test.McpEvents.Subscription
               occurrence AshAi.Test.McpEvents.Occurrence
               delivery AshAi.Test.McpEvents.Delivery
               """,
               [AshAi.Test.McpEvents.Thread, plain_space_resource()]
             ) =~ "but not the AshAi extension"
    end

    test "a storage resource is the domain's and written with its macro" do
      assert domain_refusal(
               """
               subscription AshAi.Test.McpEvents.Thread
               occurrence AshAi.Test.McpEvents.Occurrence
               delivery AshAi.Test.McpEvents.Delivery
               """,
               [AshAi.Test.McpEvents.Thread]
             ) =~ "is not written with `use AshAi.McpEvents.Subscription`"
    end
  end

  ## Helpers

  defp subscribe(name, args, principal \\ "owner", url \\ "https://r.example.com/cb") do
    Subscriptions.subscribe(
      %{
        "name" => name,
        "arguments" => args,
        "delivery" => %{"mode" => "webhook", "url" => url, "secret" => secret(5)}
      },
      events: [AshAi.Test.McpEvents],
      actor: %{id: principal}
    )
  end

  defp close!(ticket), do: ticket |> Ash.Changeset.for_update(:close, %{}) |> Ash.update!()

  defp resource_refusal(declarations, opts \\ []) do
    module = Module.concat(__MODULE__, :"Resource#{System.unique_integer([:positive])}")

    queue =
      if Keyword.get(opts, :queue?, true) do
        """
        queue do
          domain AshAi.Test.McpEvents.Queue

          space :flow do
            attribute :state
            transition :close, from: :open, to: :closed
          end
        end
        """
      else
        ""
      end

    extensions =
      if Keyword.get(opts, :queue?, true), do: "[AshAi, AshQueue.Resource]", else: "[AshAi]"

    capture_io(:stderr, fn ->
      Module.create(
        module,
        Code.string_to_quoted!("""
        use Ash.Resource, data_layer: Ash.DataLayer.Ets, extensions: #{extensions},
          validate_domain_inclusion?: false

        attributes do
          attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
          attribute :title, :string, public?: true
          attribute :secret, :string
          attribute :meta, :map, public?: true
          attribute :state, :atom, default: :open, public?: true, constraints: [one_of: [:open, :closed]]
        end

        actions do
          defaults [:read, :destroy, create: [:id, :title], update: [:title]]

          action :ping, :string do
            run fn _input, _context -> {:ok, "pong"} end
          end
        end

        #{queue}

        mcp_events do
          #{declarations}
        end
        """),
        Macro.Env.location(__ENV__)
      )
    end)

    refusal_message(module)
  end

  defp domain_refusal(section, resources \\ []) do
    module = Module.concat(__MODULE__, :"Domain#{System.unique_integer([:positive])}")

    resources =
      Enum.map_join(
        resources ++
          [
            AshAi.Test.McpEvents.Subscription,
            AshAi.Test.McpEvents.Occurrence,
            AshAi.Test.McpEvents.Delivery
          ],
        "\n",
        &"resource #{inspect(&1)}"
      )

    capture_io(:stderr, fn ->
      Module.create(
        module,
        Code.string_to_quoted!("""
        use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

        resources do
          #{resources}
        end

        mcp_events do
          #{section}
        end
        """),
        Macro.Env.location(__ENV__)
      )
    end)

    refusal_message(module)
  end

  defp refusal_message(module) do
    case VerifyEvents.verify(module.spark_dsl_config()) do
      :ok -> :ok
      {:error, %Spark.Error.DslError{message: message}} -> message
    end
  end

  defp plain_space_resource do
    module = Module.concat(__MODULE__, :"Plain#{System.unique_integer([:positive])}")

    capture_io(:stderr, fn ->
      Module.create(
        module,
        Code.string_to_quoted!("""
        use Ash.Resource, data_layer: Ash.DataLayer.Ets, extensions: [AshQueue.Resource],
          validate_domain_inclusion?: false

        attributes do
          attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
          attribute :state, :atom, default: :open, public?: true, constraints: [one_of: [:open, :closed]]
        end

        actions do
          defaults [:read, create: [:id]]
        end

        queue do
          domain AshAi.Test.McpEvents.Queue

          space :flow do
            attribute :state
            transition :close, from: :open, to: :closed
          end
        end
        """),
        Macro.Env.location(__ENV__)
      )
    end)

    module
  end
end
