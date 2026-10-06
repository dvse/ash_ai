# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Storage do
  @moduledoc """
  The three MCP Events storage resources (BLENDED-026), written with `use` macros:

      defmodule MyApp.McpEventSubscription do
        use AshAi.McpEvents.Subscription,
          domain: MyApp.Domain,
          queue_domain: MyApp.Queue,
          data_layer: AshPostgres.DataLayer,
          occurrence: MyApp.McpEventOccurrence

        postgres do
          table "mcp_event_subscriptions"
          repo MyApp.Repo
        end
      end

  Each macro expands to an ordinary Ash resource with the `AshQueue.Resource` extension: its
  attributes, private actions and `queue` block are written out in the module, so AshQueue's own
  transformers (`BuildSpace`, `BuildEdges`, `BuildPlan`) and verifiers see a declared space and
  declared transitions, exactly as in a hand-written resource. A Spark transformer that added
  `queue` entities would have to run ahead of AshQueue's transformers and repeat their ordering
  contract; a macro keeps AshQueue the only author of the machine. The application adds its data
  layer's section (`postgres do ... end`, `ets do ... end`) in the module body.

  Options of every macro: `domain` (the domain whose `mcp_events` section names this resource),
  `queue_domain` (the AshQueue domain running its edges), `data_layer`, `queue` (default
  `:default`), `extensions` and `authorizers` (added to the resource's). The subscription also
  takes `occurrence` (its `occurrences` relationship's destination).

  The machine:

    * Subscription, space `lifecycle` over `state` (`active | expired`): automatic `expire`
      (`expires_at <= now()`, fold, `to: :expired`, exhausted to `:expired`); the spaceless
      `collect` edge (`state == :active and exists(occurrences, sort_key > parent(cursor))`,
      fold, `consumes_match?`), whose body (`AshAi.McpEvents.Changes.Collect`) runs as the
      subscriber persisted on the row; the spaceless `prune` edge destroys expired rows.
    * Occurrence: the spaceless `prune` edge destroys rows whose `prune_at <= now()`.
    * Delivery, space `delivery` over `state` (`pending | delivered | failed`): automatic
      `deliver` (effect, decision `to: [:delivered, :failed]`, backoff 1 s, 5 s, 30 s, 2 min,
      exhausted via the commanded `give_up` after 5 attempts).
  """

  @doc false
  def resource_opts(opts, caller) do
    domain = Keyword.fetch!(opts, :domain)
    data_layer = Keyword.fetch!(opts, :data_layer)

    if Keyword.get(opts, :queue_domain) == nil do
      raise ArgumentError,
            "#{inspect(caller.module)}: MCP Events storage needs `queue_domain:` (the AshQueue domain running its edges)"
    end

    [
      domain: domain,
      data_layer: data_layer,
      extensions: [AshQueue.Resource | Keyword.get(opts, :extensions, [])],
      authorizers: Keyword.get(opts, :authorizers, []),
      validate_domain_inclusion?: Keyword.get(opts, :validate_domain_inclusion?, true)
    ]
  end

  @doc false
  # A template written as user code (variables without macro hygiene), as `expr/1` reads them.
  def template(source), do: Code.string_to_quoted!(source)

  @doc false
  def require_ash_queue!(caller) do
    unless Code.ensure_loaded?(AshQueue.Resource) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "MCP Events storage runs on AshQueue; add {:ash_queue, ...} to your dependencies"
    end
  end
end

defmodule AshAi.McpEvents.Subscription do
  @moduledoc """
  The MCP Events subscription resource (BLENDED-026). See `AshAi.McpEvents.Storage`.

  One row per `sub_` id: `principal`, `name`, `arguments` (normalized), `url`, `server_url`,
  `secrets` (sensitive, newest first), `rotation_ends_at`, `expires_at`, `cursor`, `requester`
  (the subscriber's actor as its `AshQueue.ActorPersister` stored it), `verified_at` (when its
  callback URL last passed verification; the 24 h verification cache per principal and URL) and
  `state` (`active | expired`).
  """

  defmacro __using__(opts) do
    AshAi.McpEvents.Storage.require_ash_queue!(__CALLER__)
    resource_opts = AshAi.McpEvents.Storage.resource_opts(opts, __CALLER__)
    queue_domain = Keyword.fetch!(opts, :queue_domain)
    occurrence = Keyword.fetch!(opts, :occurrence)
    queue = Keyword.get(opts, :queue, :default)
    expire_where = AshAi.McpEvents.Storage.template("expr(expires_at <= now())")

    collect_where =
      AshAi.McpEvents.Storage.template(
        "expr(state == :active and exists(occurrences, sort_key > parent(cursor)))"
      )

    prune_where = AshAi.McpEvents.Storage.template("expr(state == :expired)")

    quote do
      use Ash.Resource, unquote(resource_opts)

      require Ash.Expr

      @doc false
      def __mcp_events_role__, do: :subscription

      attributes do
        attribute :id, :string,
          primary_key?: true,
          allow_nil?: false,
          writable?: true,
          public?: true

        attribute :principal, :string, allow_nil?: false
        attribute :name, :string, allow_nil?: false
        attribute :arguments, :map, allow_nil?: false, default: %{}
        attribute :url, :string, allow_nil?: false
        attribute :server_url, :string
        attribute :secrets, {:array, :string}, allow_nil?: false, sensitive?: true
        attribute :rotation_ends_at, :utc_datetime_usec
        attribute :expires_at, :utc_datetime_usec, allow_nil?: false
        attribute :verified_at, :utc_datetime_usec
        attribute :cursor, :string, allow_nil?: false
        attribute :requester, :map, sensitive?: true

        attribute :state, :atom,
          allow_nil?: false,
          default: :active,
          constraints: [one_of: [:active, :expired]]
      end

      relationships do
        has_many :occurrences, unquote(occurrence) do
          source_attribute :name
          destination_attribute :name
          public? false
        end
      end

      actions do
        defaults [:read]

        create :subscribe do
          public? false

          accept [
            :id,
            :principal,
            :name,
            :arguments,
            :url,
            :server_url,
            :secrets,
            :rotation_ends_at,
            :expires_at,
            :verified_at,
            :cursor,
            :requester
          ]
        end

        update :refresh do
          public? false
          require_atomic? false

          accept [
            :server_url,
            :secrets,
            :rotation_ends_at,
            :expires_at,
            :verified_at,
            :requester
          ]
        end

        update :expire do
          public? false
          require_atomic? false
          accept []
        end

        update :collect do
          public? false
          require_atomic? false
          accept []
          change AshAi.McpEvents.Changes.Collect
        end

        destroy :unsubscribe do
          public? false
          primary? true
        end

        destroy :prune do
          public? false
        end
      end

      queue do
        domain unquote(queue_domain)

        space :lifecycle do
          attribute :state

          transition :expire, :active do
            queue(unquote(queue))
            mode(:fold)
            where unquote(expire_where)
            to :expired
            exhausted(to: :expired, after: 3)
          end
        end

        transition :collect do
          queue(unquote(queue))
          mode(:fold)
          where unquote(collect_where)
          consumes_match?(true)
          max_attempts(3)
        end

        transition :prune do
          queue(unquote(queue))
          where unquote(prune_where)
          consumes_match?(true)
        end
      end
    end
  end
end

defmodule AshAi.McpEvents.Occurrence do
  @moduledoc """
  The MCP Events occurrence resource (BLENDED-026): one row per firing, written by
  `AshAi.McpEvents.Changes.Emit` in the writer's transaction. `id` is the event id (`evt_`,
  time-ordered); `name`, `resource`, `key` (the record's primary key), `facts` (the filter fields'
  values at the firing), `occurred_at`, `sort_key` and `prune_at` (24 h later). See
  `AshAi.McpEvents.Storage`.
  """

  defmacro __using__(opts) do
    AshAi.McpEvents.Storage.require_ash_queue!(__CALLER__)
    resource_opts = AshAi.McpEvents.Storage.resource_opts(opts, __CALLER__)
    queue_domain = Keyword.fetch!(opts, :queue_domain)
    queue = Keyword.get(opts, :queue, :default)
    prune_where = AshAi.McpEvents.Storage.template("expr(prune_at <= now())")

    quote do
      use Ash.Resource, unquote(resource_opts)

      require Ash.Expr

      @doc false
      def __mcp_events_role__, do: :occurrence

      attributes do
        attribute :id, :string,
          primary_key?: true,
          allow_nil?: false,
          writable?: true,
          public?: true

        attribute :name, :string, allow_nil?: false
        attribute :resource, :string, allow_nil?: false
        attribute :key, :map, allow_nil?: false
        attribute :facts, :map, allow_nil?: false, default: %{}
        attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
        attribute :sort_key, :string, allow_nil?: false
        attribute :prune_at, :utc_datetime_usec, allow_nil?: false
      end

      actions do
        defaults [:read]

        create :emit do
          public? false
          accept [:id, :name, :resource, :key, :facts, :occurred_at, :sort_key, :prune_at]
        end

        destroy :prune do
          public? false
          primary? true
        end
      end

      queue do
        domain unquote(queue_domain)

        transition :prune do
          queue(unquote(queue))
          where unquote(prune_where)
          consumes_match?(true)
        end
      end
    end
  end
end

defmodule AshAi.McpEvents.Delivery do
  @moduledoc """
  The MCP Events delivery resource (BLENDED-026): one row per (subscription, event), `id`
  `dlv_` and a hash of the two ids, with the body frozen at collection (every attempt sends the
  same bytes, with a fresh timestamp and signature). `state` is `pending | delivered | failed`;
  `attempt`, `last_status` and `last_error` record how it ended. See `AshAi.McpEvents.Storage`.
  """

  defmacro __using__(opts) do
    AshAi.McpEvents.Storage.require_ash_queue!(__CALLER__)
    resource_opts = AshAi.McpEvents.Storage.resource_opts(opts, __CALLER__)
    queue_domain = Keyword.fetch!(opts, :queue_domain)
    queue = Keyword.get(opts, :queue, :default)
    attempts = AshAi.McpEvents.max_attempts()

    quote do
      use Ash.Resource, unquote(resource_opts)

      @doc false
      def __mcp_events_role__, do: :delivery

      attributes do
        attribute :id, :string,
          primary_key?: true,
          allow_nil?: false,
          writable?: true,
          public?: true

        attribute :subscription_id, :string, allow_nil?: false
        attribute :event_id, :string, allow_nil?: false
        attribute :name, :string, allow_nil?: false

        attribute :body, :string,
          allow_nil?: false,
          constraints: [trim?: false, allow_empty?: true]

        attribute :attempt, :integer, allow_nil?: false, default: 0
        attribute :last_status, :integer
        attribute :last_error, :string

        attribute :state, :atom,
          allow_nil?: false,
          default: :pending,
          constraints: [one_of: [:pending, :delivered, :failed]]
      end

      actions do
        defaults [:read]

        create :enqueue do
          public? false
          accept [:id, :subscription_id, :event_id, :name, :body]
        end

        update :deliver do
          public? false
          require_atomic? false
          transaction? false
          accept []
          change AshAi.McpEvents.Changes.Deliver
        end

        update :give_up do
          public? false
          require_atomic? false
          accept []
          argument :error, :term, allow_nil?: true
          argument :attempt, :integer, allow_nil?: true
          change AshAi.McpEvents.Changes.GiveUp
        end

        destroy :destroy do
          public? false
          primary? true
        end
      end

      queue do
        domain unquote(queue_domain)

        space :delivery do
          attribute :state

          transition(:give_up, from: :pending, to: :failed)

          transition :deliver, :pending do
            queue(unquote(queue))
            mode(:effect)
            to [:delivered, :failed]
            max_attempts(unquote(attempts))
            backoff(&AshAi.McpEvents.Changes.Deliver.backoff/1)
            exhausted(via: :give_up, after: unquote(attempts))
          end
        end
      end
    end
  end
end
