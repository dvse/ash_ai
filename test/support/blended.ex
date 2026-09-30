# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for the BLENDED-* additions (see BLENDED.md). The resources cover every
# result shape a tool can produce, so `test/ash_ai/blended/output_schema_test.exs` can
# validate each shape's `structuredContent` against the emitted `outputSchema`.

defmodule AshAi.Test.Blended.Flags do
  @moduledoc false
  def yes, do: true
end

defmodule AshAi.Test.Blended.DiscoveryOnly do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  def match?(_actor, %{context: %{private: %{ash_ai_pre_check?: true}}}, _opts), do: true
  def match?(_actor, _context, _opts), do: false
  def describe(_opts), do: "allowed only during tool discovery"
end

defmodule AshAi.Test.Blended.Mood do
  @moduledoc false
  use Ash.Type.Enum, values: [:happy, :sad]
end

defmodule AshAi.Test.Blended.Money do
  @moduledoc false
  use Ash.Type.NewType, subtype_of: :decimal, constraints: [min: 0]
end

defmodule AshAi.Test.Blended.Summary do
  @moduledoc false
  use Ash.TypedStruct

  typed_struct do
    field :title, :string, allow_nil?: false
    field :score, :decimal
    field :ratio, :float
    field :mood, AshAi.Test.Blended.Mood
    field :at, :utc_datetime
  end
end

defmodule AshAi.Test.Blended.Address do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, public?: true
    attribute :city, :string, public?: true, allow_nil?: false
  end
end

defmodule AshAi.Test.Blended.Author do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.Blended,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :name, :string, public?: true, allow_nil?: false
  end

  identities do
    identity :unique_name, [:name], pre_check_with: AshAi.Test.Blended
  end

  relationships do
    has_many :posts, AshAi.Test.Blended.Post, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:id, :name], update: [:name]]
  end
end

defmodule AshAi.Test.Blended.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.Blended,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
  end

  relationships do
    belongs_to :post, AshAi.Test.Blended.Post, public?: true
  end

  actions do
    defaults [:read, create: [:body, :post_id]]
  end
end

defmodule AshAi.Test.Blended.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.Blended,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAi]

  alias AshAi.Test.Blended.{Address, Mood, Money, Summary}

  ets do
    private? true
  end

  # BLENDED-012: the resource-level setting wins over the domain's `:hide`.
  tools do
    forbidden_fields(:display)

    tool :resource_list_posts, :read
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :body, :string, public?: true
    attribute :score, :decimal, public?: true
    attribute :mood, Mood, public?: true
    attribute :secret, :string, public?: true
    attribute :internal, :string
    attribute :address, Address, public?: true
    attribute :tags, {:array, :string}, public?: true
  end

  relationships do
    belongs_to :author, AshAi.Test.Blended.Author, public?: true
    has_many :comments, AshAi.Test.Blended.Comment, public?: true
  end

  calculations do
    calculate :title_bang, :string, expr(title <> "!"), public?: true
    calculate :hidden_calc, :integer, expr(1), public?: true, field?: false
  end

  aggregates do
    count :comment_count, :comments, public?: true
  end

  policies do
    policy action([:protected, :protected_create]) do
      authorize_if AshAi.Test.Blended.DiscoveryOnly
    end

    policy always() do
      authorize_if always()
    end
  end

  field_policies do
    field_policy :secret do
      authorize_if actor_attribute_equals(:admin, true)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    default_accept [
      :id,
      :title,
      :body,
      :score,
      :mood,
      :secret,
      :internal,
      :address,
      :tags,
      :author_id
    ]

    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      # Declared without a default: the carrier counts as `false`.
      metadata :blocking?, :boolean
    end

    create :protected_create

    read :plain

    read :page_offset do
      pagination offset?: true, countable: :by_default, required?: false, default_limit: 2
    end

    read :page_keyset do
      pagination keyset?: true, required?: false, default_limit: 2
    end

    read :page_both do
      pagination offset?: true, keyset?: true, required?: false, default_limit: 2
    end

    read :search do
      metadata :read_only?, :boolean, default: false
      metadata :blocking?, :boolean, default: &AshAi.Test.Blended.Flags.yes/0
    end

    read :await_ready do
      metadata :blocking?, :boolean, default: true
    end

    read :hidden_read do
      public? false
    end

    update :publish do
      accept [:title]
      metadata :destructive?, :boolean, default: false
    end

    action :stats, :map do
      constraints fields: [
                    total: [type: :integer, allow_nil?: false],
                    average: [type: :decimal],
                    label: [type: :string],
                    anything: [type: :term],
                    ok?: [type: :boolean, allow_nil?: false],
                    tags: [type: {:array, :string}, constraints: [nil_items?: true]]
                  ]

      run fn _input, _context ->
        {:ok,
         %{
           total: 3,
           average: Decimal.new("1.50"),
           label: nil,
           anything: [1],
           ok?: true,
           tags: ["a", nil]
         }}
      end
    end

    action :summary, Summary do
      run fn _input, _context ->
        {:ok,
         Summary.new!(%{
           title: "t",
           score: Decimal.new("9.99"),
           ratio: 0.5,
           mood: :happy,
           at: ~U[2026-09-30 00:00:00Z]
         })}
      end
    end

    action :loose_struct, :struct do
      constraints fields: [name: [type: :string, allow_nil?: false]]
      run fn _input, _context -> {:ok, %{name: "loose"}} end
    end

    action :post_record, :struct do
      constraints instance_of: __MODULE__

      run fn _input, _context ->
        __MODULE__
        |> Ash.Query.for_read(:read)
        |> Ash.Query.limit(1)
        |> Ash.read_one(authorize?: false)
      end
    end

    action :address, Address do
      run fn _input, _context -> {:ok, %Address{street: nil, city: "Brisbane"}} end
    end

    action :pick, :union do
      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:record, :text, :number, :loose, :loose_map, :free]]

      constraints types: [
                    record: [
                      type: :map,
                      constraints: [fields: [a: [type: :string, allow_nil?: false]]]
                    ],
                    text: [type: :string],
                    number: [type: :integer],
                    loose: [type: :term],
                    free: [type: :map]
                  ]

      run fn input, _context ->
        case input.arguments.kind do
          :record -> {:ok, %Ash.Union{type: :record, value: %{a: "x"}}}
          :text -> {:ok, %Ash.Union{type: :text, value: "hello"}}
          :number -> {:ok, %Ash.Union{type: :number, value: 42}}
          :loose -> {:ok, %Ash.Union{type: :loose, value: "raw"}}
          :loose_map -> {:ok, %Ash.Union{type: :loose, value: %{"k" => "v"}}}
          :free -> {:ok, %Ash.Union{type: :free, value: %{"any" => 1}}}
        end
      end
    end

    action :keywords, :keyword do
      constraints fields: [a: [type: :integer], b: [type: :string]]
      run fn _input, _context -> {:ok, [a: 1]} end
    end

    action :pair, :tuple do
      constraints fields: [left: [type: :string], right: [type: :integer]]
      run fn _input, _context -> {:ok, {"l", 2}} end
    end

    action :price, Money do
      run fn _input, _context -> {:ok, Decimal.new("12.50")} end
    end

    action :mood_now, Mood do
      run fn _input, _context -> {:ok, :sad} end
    end

    action :loose_map, :map do
      run fn _input, _context -> {:ok, %{"free" => ["form"]}} end
    end

    action :scalar, :string do
      run fn _input, _context -> {:ok, "scalar"} end
    end

    action :numbers, {:array, :integer} do
      run fn _input, _context -> {:ok, [1, 2]} end
    end

    action :maybe, :map do
      allow_nil? true
      run fn _input, _context -> {:ok, nil} end
    end

    action :nothing do
      run fn _input, _context -> :ok end
    end

    action :needs_input, :map do
      argument :name, :string, allow_nil?: false
      run fn input, _context -> {:ok, %{name: input.arguments.name}} end
    end

    action :await, :map do
      run fn _input, _context -> {:ok, %{done: true}} end
    end

    action :wait_for, :map do
      argument :timeout_ms, :integer, default: 1000
      run fn _input, _context -> {:ok, %{done: true}} end
    end

    action :protected, :map do
      run fn _input, _context -> {:ok, %{ok: true}} end
    end
  end
end

defmodule AshAi.Test.Blended do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi]

  alias AshAi.Test.Blended.{Author, Comment, Post}

  tools do
    # Read shapes: unpaginated list, pages, count/exists/aggregate, select/load.
    tool :list_posts, Post, :read,
      load: [:title_bang, :comment_count, :hidden_calc, author: [:posts], comments: [post: []]]

    tool :select_posts, Post, :read, select: [:title, :internal], refine?: false
    tool :count_posts, Post, :read, action_parameters: [result_type: [:count]]
    tool :filter_posts, Post, :read, action_parameters: [:filter, :result_type]
    tool :sort_posts, Post, :read, action_parameters: [:sort]
    tool :none_posts, Post, :read, action_parameters: []
    tool :plain_posts, Post, :plain, load: [comments: [:body]]
    tool :offset_posts, Post, :page_offset, refine?: false
    tool :offset_posts_all, Post, :page_offset
    tool :keyset_posts, Post, :page_keyset, refine?: false
    tool :both_posts, Post, :page_both, refine?: false
    tool :get_post, Post, :read, get_by: :id, load: [:author]
    tool :dynamic_posts, Post, :read, refine?: false, load: &__MODULE__.dynamic_load/1
    tool :search_posts, Post, :search, refine?: false
    tool :await_posts, Post, :await_ready, refine?: false, blocking?: false

    # Write shapes.
    tool :create_post, Post, :create,
      example: ~s|{"input": {"title": "Hello"}}|,
      annotations: [title: "Create a post", idempotent?: true, open_world?: true],
      hints: &__MODULE__.create_hint/1

    tool :update_post, Post, :update, load: [:comment_count]
    tool :destroy_post, Post, :destroy
    tool :create_author, Author, :create
    tool :list_comments, Comment, :read, refine?: false

    # Generic shapes.
    tool :stats, Post, :stats, hints: &__MODULE__.nil_hint/1
    tool :stats_no_schema, Post, :stats, output_schema?: false
    # BLENDED-015: the module forms of `hints`.
    tool :stats_hinted, Post, :stats, hints: {AshAi.Test.Blended.TotalHint, prefix: "Totals"}
    tool :stats_module_hint, Post, :stats, hints: AshAi.Test.Blended.TotalHint
    tool :summary, Post, :summary, hints: &__MODULE__.non_string_hint/1
    tool :loose_struct, Post, :loose_struct
    tool :post_record, Post, :post_record, load: [:title_bang], hints: &__MODULE__.raising_hint/1
    tool :address, Post, :address, hints: &__MODULE__.throwing_hint/1
    tool :pick, Post, :pick
    tool :keywords, Post, :keywords
    tool :pair, Post, :pair
    tool :price, Post, :price
    tool :mood_now, Post, :mood_now
    tool :loose_map, Post, :loose_map
    tool :scalar, Post, :scalar, hints: &__MODULE__.create_hint/1
    tool :numbers, Post, :numbers
    tool :maybe, Post, :maybe
    tool :nothing, Post, :nothing, output_schema?: false
    tool :needs_input, Post, :needs_input
    tool :await_now, Post, :await, continuation_target?: true
    tool :wait_for, Post, :wait_for, blocking?: true
    tool :protected, Post, :protected
    tool :protected_create, Post, :protected_create

    expose Post do
      delivery_hints(&__MODULE__.post_delivery_hints/1)

      interface(:publish_post,
        description: "Publishes a post.",
        example: ~s|{"id": "...", "input": {"title": "Final"}}|,
        annotations: [read_only?: true]
      )

      interface(:post_by_title, refine?: false)
      interface(:hidden_posts)
      interface(:await)
    end

    expose Author do
      # BLENDED-015: the module form of `delivery_hints`.
      delivery_hints({AshAi.Test.Blended.AuthorDeliveryHints, note: "Write their first post"})
      interface(:author_by_id)
      interface(:author_by_name)
      interface(:rename_author)
      interface(:drop_author_by_name)
    end
  end

  resources do
    resource Post do
      define :publish_post, action: :publish
      define :post_by_title, action: :read, get_by: [:title]
      define :hidden_posts, action: :hidden_read
      define :await, action: :wait_for
    end

    resource Author do
      define :author_by_id, action: :read, get_by: [:id]
      define :author_by_name, action: :read, get_by_identity: :unique_name
      define :rename_author, action: :update, get_by_identity: :unique_name
      define :drop_author_by_name, action: :destroy
    end

    resource Comment
  end

  @doc false
  def dynamic_load(_input), do: [:title_bang]

  @doc false
  def create_hint(%{title: title}), do: "Created #{title}. Publish it with publish_post."
  def create_hint(_result), do: "unreachable"

  @doc false
  def nil_hint(_result), do: nil

  @doc false
  def non_string_hint(_result), do: :not_a_string

  @doc false
  def raising_hint(_result), do: raise("hint failed")

  @doc false
  def throwing_hint(_result), do: throw(:hint_thrown)

  @doc false
  def post_delivery_hints(%{tool: "create_post", result: %{id: id}}) do
    [
      %{note: "Publish it", action: :publish_post, args: %{title: "Published"}, id: id},
      %{"note" => "Or rename it", "action" => "update", "args" => "not a map"},
      %{note: "Just a note", action: :no_such_action},
      %{resource: AshAi.Test.Blended.Author, action: :author_by_id, args: %{}},
      %{action: :no_such_action},
      :not_a_map
    ]
  end

  def post_delivery_hints(%{tool: "update_post"}), do: [%{action: :no_such_action}]
  def post_delivery_hints(%{tool: "destroy_post"}), do: :not_a_list
  def post_delivery_hints(%{tool: "get_post"}), do: raise("delivery hints failed")
  def post_delivery_hints(_context), do: nil
end

defmodule AshAi.Test.Blended.TotalHint do
  @moduledoc false
  # BLENDED-015: a result hint as a module, with and without options.
  use AshAi.Hints

  @impl true
  def hint(%{total: total}, opts), do: "#{Keyword.get(opts, :prefix, "Total")}: #{total}."
end

defmodule AshAi.Test.Blended.AuthorDeliveryHints do
  @moduledoc false
  # BLENDED-015: delivery hints as a module with options; only `create_author` gets one.
  use AshAi.DeliveryHints

  @impl true
  def delivery_hints(%{tool: "create_author"}, opts), do: [%{note: Keyword.fetch!(opts, :note)}]
  def delivery_hints(_context, _opts), do: nil
end
