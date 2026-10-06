# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-026 (see BLENDED.md): MCP Events over ETS and an ETS AshQueue.
#
# `Thread` is Oberon's Amp thread as a resource: its `turn` space moves `working -> ended` when a
# turn ends (`thread.turn_ended`, declared, with Oberon's filter and payload fields), and back
# with `resume`, so a thread has many turns and its space has no terminal state (no default
# events). `Ticket` exercises the defaults: its `flow` space has two terminal states, one default
# replaced by a declaration, plus an `action` event. A thread with an `owner` is readable only by
# that actor; its read action counts its reads.

defmodule AshAi.Test.McpEvents.Clock do
  @moduledoc false
  # A settable clock (`config :ash_ai, :mcp_events_clock`), like Oberon's injected `now`.
  use Agent

  def start(%DateTime{} = at) do
    case Agent.start(fn -> at end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> set(at)
    end
  end

  def set(%DateTime{} = at), do: Agent.update(__MODULE__, fn _ -> at end)
  def advance(ms), do: Agent.update(__MODULE__, &DateTime.add(&1, ms, :millisecond))
  def utc_now, do: Agent.get(__MODULE__, & &1)
end

defmodule AshAi.Test.McpEvents.Receiver do
  @moduledoc false
  # Oberon's test `receiver()`: answers verification challenges, plays scripted responses to
  # events (`{status, body}` or `{:error, message}`), and keeps every request.
  use Agent

  def start do
    state = %{requests: [], responses: [], handler: nil}

    case Agent.start(fn -> state end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Agent.update(__MODULE__, fn _ -> state end)
    end
  end

  def script(responses), do: Agent.update(__MODULE__, &%{&1 | responses: responses})
  def handler(fun), do: Agent.update(__MODULE__, &%{&1 | handler: fun})
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def events,
    do: Enum.reject(requests(), &match?(%{"type" => _}, Jason.decode!(&1.body)))

  def event_bodies, do: Enum.map(events(), &Jason.decode!(&1.body))

  def post(request) do
    {handler, next} =
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | requests: [request | state.requests]}

        case Jason.decode!(request.body) do
          %{"type" => "verification"} ->
            {{state.handler, :verification}, state}

          _event ->
            case state.responses do
              [next | rest] -> {{state.handler, next}, %{state | responses: rest}}
              [] -> {{state.handler, {200, ""}}, state}
            end
        end
      end)

    cond do
      handler ->
        handler.(request)

      next == :verification ->
        %{"challenge" => challenge} = Jason.decode!(request.body)
        {:ok, %{status: 200, body: Jason.encode!(%{challenge: challenge})}}

      match?({:error, _}, next) ->
        next

      true ->
        {status, body} = next
        {:ok, %{status: status, body: body}}
    end
  end
end

defmodule AshAi.Test.McpEvents.Sender do
  @moduledoc false
  use AshAi.McpEvents.Sender

  @impl AshAi.McpEvents.Sender
  def post(request, _opts), do: AshAi.Test.McpEvents.Receiver.post(request)
end

defmodule AshAi.Test.McpEvents.ActorPersister do
  @moduledoc false
  # The test actors are maps `%{id: "owner"}`.
  def store(%{id: id}), do: {:ok, %{"id" => id}}
  def store(_actor), do: {:error, "no id"}
  def lookup(%{"id" => id}), do: {:ok, %{id: id}}
  def lookup(_stored), do: {:error, "not stored"}
end

defmodule AshAi.Test.McpEvents.Reads do
  @moduledoc false
  # Counts reads of threads (Oberon: "does not read the thread when nobody is subscribed").
  def reset, do: :persistent_term.put(__MODULE__, :counters.new(1, []))
  def count, do: :counters.get(:persistent_term.get(__MODULE__), 1)
  def bump, do: :counters.add(:persistent_term.get(__MODULE__), 1, 1)
end

defmodule AshAi.Test.McpEvents.Queue do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshQueue.Domain],
    otp_app: :ash_ai,
    validate_config_inclusion?: false

  queue do
    storage(Ash.DataLayer.Ets)

    runtime do
      queues do
        queue(:mcp_events)
      end
    end
  end
end

defmodule AshAi.Test.McpEvents.Thread do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.McpEvents,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAi, AshQueue.Resource],
    primary_read_warning?: false

  @outcomes [:completed, :error, :cancelled, :needs_approval]

  ets do
    private? false
  end

  mcp_events do
    event "thread.turn_ended" do
      description "An Amp agent finished its turn in a thread."
      states([:ended])
      filter [:thread_id, :project, :origin, :outcome]

      payload([
        :thread_id,
        :title,
        :url,
        :project,
        :origin,
        :agent_state,
        :outcome,
        :final_message,
        :final_message_truncated
      ])
    end
  end

  queue do
    domain AshAi.Test.McpEvents.Queue

    space :turn do
      attribute :turn_state
      transition(:end_turn, from: :working, to: :ended)
      transition(:resume, from: :ended, to: :working)
    end
  end

  attributes do
    attribute :thread_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, default: "Probe", public?: true
    attribute :url, :string, allow_nil?: false, public?: true
    attribute :project, :string, allow_nil?: false, default: "amp-mcp", public?: true

    attribute :origin, :atom,
      allow_nil?: false,
      default: :other,
      public?: true,
      constraints: [one_of: [:oberon, :other]],
      description: ~s("oberon" if the thread was started through start_thread, otherwise "other".)

    attribute :agent_state, :string, allow_nil?: false, default: "idle", public?: true

    attribute :outcome, :atom,
      allow_nil?: false,
      default: :completed,
      public?: true,
      constraints: [one_of: @outcomes]

    attribute :final_message, :string,
      allow_nil?: false,
      default: "",
      public?: true,
      constraints: [allow_empty?: true, trim?: false]

    attribute :final_message_truncated, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    attribute :turn_state, :atom,
      allow_nil?: false,
      default: :working,
      public?: true,
      constraints: [one_of: [:working, :ended]]

    attribute :owner, :string
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(is_nil(owner) or owner == ^actor(:id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true

      # Counts the reads made as somebody (a subscriber); the tests' own reads have no actor.
      prepare fn query, context ->
        Ash.Query.before_action(query, fn query ->
          if context.actor, do: AshAi.Test.McpEvents.Reads.bump()
          query
        end)
      end
    end

    create :create do
      primary? true
      accept [:thread_id, :title, :project, :origin, :owner]

      change fn changeset, _context ->
        id = Ash.Changeset.get_attribute(changeset, :thread_id)
        Ash.Changeset.force_change_attribute(changeset, :url, "https://ampcode.com/threads/#{id}")
      end
    end

    update :end_turn do
      require_atomic? false
      accept [:agent_state, :outcome, :final_message, :final_message_truncated]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:title, :project, :origin, :owner]
    end
  end
end

defmodule AshAi.Test.McpEvents.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.McpEvents,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshAi, AshQueue.Resource]

  ets do
    private? false
  end

  mcp_events do
    event "ticket.flow.rejected" do
      description "A ticket was rejected."
      states([:rejected])
      filter [:id, :project]
      payload([:id, :title])
    end

    event "ticket.created" do
      action :create
      filter [:project]
      payload([:id, :title, :state])
    end
  end

  queue do
    domain AshAi.Test.McpEvents.Queue

    space :flow do
      attribute :state
      transition(:close, from: :open, to: :closed)
      transition(:reject, from: :open, to: :rejected)
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :project, :string, public?: true

    attribute :state, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      constraints: [one_of: [:open, :closed, :rejected]]

    attribute :note, :string
  end

  actions do
    defaults [:read, :destroy, update: [:title]]

    create :create do
      primary? true
      accept [:id, :title, :project]
    end
  end
end

defmodule AshAi.Test.McpEvents.Subscription do
  @moduledoc false
  use AshAi.McpEvents.Subscription,
    domain: AshAi.Test.McpEvents,
    queue_domain: AshAi.Test.McpEvents.Queue,
    data_layer: Ash.DataLayer.Ets,
    occurrence: AshAi.Test.McpEvents.Occurrence,
    queue: :mcp_events

  ets do
    private? false
  end
end

defmodule AshAi.Test.McpEvents.Occurrence do
  @moduledoc false
  use AshAi.McpEvents.Occurrence,
    domain: AshAi.Test.McpEvents,
    queue_domain: AshAi.Test.McpEvents.Queue,
    data_layer: Ash.DataLayer.Ets,
    queue: :mcp_events

  ets do
    private? false
  end
end

defmodule AshAi.Test.McpEvents.Delivery do
  @moduledoc false
  use AshAi.McpEvents.Delivery,
    domain: AshAi.Test.McpEvents,
    queue_domain: AshAi.Test.McpEvents.Queue,
    data_layer: Ash.DataLayer.Ets,
    queue: :mcp_events

  ets do
    private? false
  end
end

defmodule AshAi.Test.McpEvents do
  @moduledoc false
  use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

  mcp_events do
    subscription(AshAi.Test.McpEvents.Subscription)
    occurrence(AshAi.Test.McpEvents.Occurrence)
    delivery(AshAi.Test.McpEvents.Delivery)
    sender(AshAi.Test.McpEvents.Sender)
    actor_persister(AshAi.Test.McpEvents.ActorPersister)
  end

  resources do
    resource AshAi.Test.McpEvents.Thread
    resource AshAi.Test.McpEvents.Ticket
    resource AshAi.Test.McpEvents.Subscription
    resource AshAi.Test.McpEvents.Occurrence
    resource AshAi.Test.McpEvents.Delivery
  end
end

defmodule AshAi.Test.McpEventsCase do
  @moduledoc false
  # The harness: a settable clock, the scripted receiver, and `pump!/0`, which runs AshQueue as
  # production does with the reactive wakes left on: a cron tick (the sweep), the stager, then a
  # drain, until nothing is live. Every pass is at most one delivery attempt per delivery.
  use ExUnit.CaseTemplate

  alias AshAi.Test.McpEvents.{Clock, Queue, Reads, Receiver}

  @resources [
    AshAi.Test.McpEvents.Thread,
    AshAi.Test.McpEvents.Ticket,
    AshAi.Test.McpEvents.Subscription,
    AshAi.Test.McpEvents.Occurrence,
    AshAi.Test.McpEvents.Delivery
  ]

  using do
    quote do
      import AshAi.Test.McpEventsCase
      alias AshAi.Test.McpEvents.{Clock, Receiver, Thread, Ticket}
    end
  end

  setup do
    reset!()

    test_pid = self()
    handler = "mcp-events-retry-#{inspect(test_pid)}"

    :telemetry.attach(
      handler,
      [:ash_ai, :mcp_events, :retry],
      &__MODULE__.forward_retry/4,
      test_pid
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.delete_env(:ash_ai, :mcp_events_clock)
      Application.delete_env(:ash_queue, :suppress_reactive_enqueue)
    end)

    :ok
  end

  @doc false
  def forward_retry(_event, %{delay_ms: delay_ms}, _meta, test_pid),
    do: send(test_pid, {:retry_delay, delay_ms})

  @doc "A fresh store, receiver and clock (Oberon's `setup()`), keeping the test's telemetry."
  def reset!(at \\ ~U[2030-10-01 12:00:00.000000Z]) do
    # Empty every table in place: `Ets.stop/1` is asynchronous, and a table being dropped while
    # the next test seeds or reads it gives StaleRecord and unknown read errors.
    for resource <- @resources ++ queue_resources(),
        row <- Ash.read!(resource, authorize?: false),
        do: :ok = Ash.DataLayer.Ets.destroy(resource, Ash.Changeset.new(row))

    Clock.start(at)
    Application.put_env(:ash_ai, :mcp_events_clock, Clock)
    Receiver.start()
    Reads.reset()
    retry_delays()

    # The sweep's own timeline: in the past (so the jobs a tick enqueues are due on the queue's
    # real clock) and never earlier than any earlier test's, since a schedule row that outlives
    # a table reset keeps the next run it was given.
    floor = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second) |> DateTime.truncate(:second)
    last = :persistent_term.get({__MODULE__, :sweep_at}, floor)

    t0 =
      if DateTime.compare(last, floor) == :gt, do: DateTime.add(last, 180, :second), else: floor

    sweep_at!(t0)
    seed = fn -> AshQueue.Seeds.apply(Queue, resources: @resources, now: DateTime.add(t0, -120, :second)) end

    case seed.() do
      :ok -> :ok
      {:error, _stale} -> :ok = seed.()
    end
  end

  def queue_resources do
    [Queue.Job, Queue.QueueControl, Queue.Cron, Queue.QueueKey]
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  @doc """
  Runs the queue until it is quiet, at most `passes` times: the sweep (a cron tick), the stager,
  a drain, then each job still waiting for its backoff run once as if its time had come (the
  queue's own clock is real time; the backoff it chose is recorded by telemetry instead of
  waited out). Every pass is at most one attempt per job.
  """
  def pump!(passes \\ 12) do
    Enum.reduce_while(1..passes, nil, fn _pass, _ ->
      at = DateTime.add(Process.get(:mcp_events_sweep_at), 61, :second)
      sweep_at!(at)
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      # The jobs that were waiting out a backoff when the pass began: their time has come.
      waiting = live_jobs()

      for job <- waiting do
        job =
          if job.state == :available,
            do: job,
            else:
              job
              |> Ash.Changeset.for_update(:stage, %{now: later})
              |> Ash.update!(authorize?: false)

        {:ok, _} = AshQueue.Test.perform_job(Queue, job, now: later)
      end

      {:ok, _} = AshQueue.MaintenancePoller.run_role_once(domain: Queue, role: :cron, now: at)

      {:ok, _} =
        AshQueue.MaintenancePoller.run_role_once(domain: Queue, role: :stager, now: later)

      {:ok, summary} = AshQueue.Test.drain_space(Queue, cap: 20)

      if summary.total == 0 and waiting == [] and live_jobs() == [],
        do: {:halt, :ok},
        else: {:cont, :ok}
    end)
  end

  defp sweep_at!(at) do
    Process.put(:mcp_events_sweep_at, at)
    :persistent_term.put({__MODULE__, :sweep_at}, at)
  end

  def live_jobs do
    Queue.Job
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.state in [:scheduled, :available, :executing, :retryable]))
  end

  @doc """
  Ends a turn of a thread (creating it, or resuming its last turn, first), with these facts:
  `project`, `origin`, `title`, `owner` set on the thread, `agent_state`, `outcome`,
  `final_message`, `final_message_truncated` by the turn.
  """
  def end_turn(thread_id, facts \\ []) do
    facts = Map.new(facts)
    thread_facts = Map.take(facts, [:project, :origin, :title, :owner])

    turn_facts =
      Map.take(facts, [:agent_state, :outcome, :final_message, :final_message_truncated])

    thread = AshAi.Test.McpEvents.Thread

    thread =
      case Ash.get(thread, thread_id, authorize?: false, error?: false) do
        {:ok, nil} ->
          Ash.create!(thread, Map.put(thread_facts, :thread_id, thread_id), authorize?: false)

        {:ok, existing} ->
          existing = Ash.update!(existing, thread_facts, authorize?: false)

          if existing.turn_state == :ended,
            do:
              existing
              |> Ash.Changeset.for_update(:resume, %{}, authorize?: false)
              |> Ash.update!(),
            else: existing
      end

    thread
    |> Ash.Changeset.for_update(:end_turn, turn_facts, authorize?: false)
    |> Ash.update!()
  end

  @doc "The retry delays recorded so far, in order."
  def retry_delays do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:retry_delay, ms} -> receive_all([ms | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def secret(fill, bytes \\ 32),
    do: "whsec_" <> Base.encode64(:binary.copy(<<fill>>, bytes))

  @doc "Signed with `secret` (any signature in the header), independent of wall-clock tolerance."
  def signed_with?(secret, request) do
    AshAi.McpEvents.Signing.verify(request.body, request.headers, secret, tolerance: false) == :ok
  end

  def subscriptions do
    Ash.read!(AshAi.Test.McpEvents.Subscription, authorize?: false)
  end

  def deliveries do
    Ash.read!(AshAi.Test.McpEvents.Delivery, authorize?: false)
  end
end
