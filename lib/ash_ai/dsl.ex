# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Dsl do
  @moduledoc """
  Spark DSL schemas and configuration for AshAi.

  This module contains all the DSL entity and section definitions that define
  how AshAi resources are configured, including tools, vectorization, and MCP resources.
  """

  require Ash.Expr

  @tool_argument_schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name of the argument."
    ],
    type: [
      type: :any,
      required: true,
      doc: "The Ash type of the argument (e.g., :string, :date, :integer)."
    ],
    constraints: [
      type: :keyword_list,
      default: [],
      doc: "Type constraints (e.g., [max_length: 10]). These are converted to JSON Schema rules."
    ],
    description: [
      type: :string,
      doc: "A description for the Agent."
    ],
    allow_nil?: [
      type: :boolean,
      default: true,
      doc: "If set to `false`, the argument is marked as required in the generated JSON Schema."
    ],
    default: [
      type: :any,
      doc: "The default value if not provided."
    ]
  ]

  # BLENDED-003..009: options shared by `tool` and `interface`.
  # BLENDED-003: from ash_hyperlang lib/ash_hyperlang/domain.ex:201 (`example`)
  # BLENDED-004: from ash_hyperlang lib/ash_hyperlang/domain.ex:205 (`refine?`)
  # BLENDED-005: from ash_hyperlang lib/ash_hyperlang/domain.ex:210 (`blocking?`)
  # BLENDED-006: from ash_hyperlang lib/ash_hyperlang/domain.ex:220 (`continuation_target`)
  # BLENDED-007: from ash_hyperlang lib/ash_hyperlang/domain.ex:225 (`hints`)
  @blended_tool_schema [
    example: [
      type: :string,
      doc: "A worked example of calling the tool. Appended to the tool description."
    ],
    refine?: [
      type: :boolean,
      default: true,
      doc:
        "Set to `false` to omit the read query envelope (`filter`, `sort`, `limit`, `offset`, `result_type`). Equivalent to `action_parameters: []`; setting `refine?: false` together with a non-empty `action_parameters` is a compile error."
    ],
    blocking?: [
      type: :boolean,
      doc:
        "Whether a call blocks until its result is ready. Defaults to the action's own `metadata :blocking?` declaration (or an action/interface named `:await`). Surfaces as `_meta[\"hyperbob/blocking\"]` and in the description."
    ],
    continuation_target?: [
      type: :boolean,
      default: false,
      doc:
        "Marks tools whose calls may be parked as await continuations. Surfaces as `_meta[\"hyperbob/continuation_target\"]`."
    ],
    # BLENDED-015: `fun | {module, opts}`, as a generic action's `run`.
    hints: [
      type: {:spark_function_behaviour, AshAi.Hints, {AshAi.Hints.Function, 1}},
      doc:
        "A function receiving the raw action result and returning a model-facing hint string or `nil`, or a module implementing `AshAi.Hints` (`module` or `{module, opts}`). The hint is appended to MCP `tools/call` results as a second text content block; `structuredContent` is unchanged."
    ],
    annotations: [
      type: :keyword_list,
      default: [],
      keys: [
        title: [type: :string, doc: "A human-readable title for the tool."],
        read_only?: [type: :boolean, doc: "MCP `readOnlyHint`."],
        destructive?: [type: :boolean, doc: "MCP `destructiveHint`."],
        idempotent?: [type: :boolean, doc: "MCP `idempotentHint`."],
        open_world?: [type: :boolean, doc: "MCP `openWorldHint`."]
      ],
      doc: """
      MCP tool annotations. Unset hints default from the action: read actions are read-only and
      non-destructive, create actions are neither, update/destroy actions are destructive, and
      generic actions are destructive and not read-only. An action's own `metadata :read_only?`
      / `metadata :destructive?` declaration (its `default`) overrides the type default.
      `idempotent?` and `open_world?` default to `false`.
      """
    ],
    output_schema?: [
      type: :boolean,
      default: true,
      doc:
        "Whether to emit an MCP `outputSchema`. Only emitted when every result the tool can return is a JSON object (i.e. always carried as `structuredContent`)."
    ],
    # BLENDED-016: OpenAI Apps SDK tool descriptor `securitySchemes`
    security_schemes: [
      type: {:list, :map},
      doc:
        "The tool's authentication schemes, as the OpenAI Apps SDK declares them: `%{type: \"noauth\"}` or `%{type: \"oauth2\", scopes: [\"...\"]}` (atom or string keys). Emitted as the tool's `securitySchemes` and mirrored in `_meta[\"securitySchemes\"]`. Unset, the MCP server's `security_schemes` option applies; when that is unset too, nothing is emitted. Declarative only: the host enforces authentication."
    ],
    # BLENDED-018: OpenAI Apps SDK `_meta["openai/fileParams"]`
    file_params: [
      type: {:list, :atom},
      default: [],
      doc:
        "Public action arguments of type `:map` or `{:array, :map}` that take files in the OpenAI Apps SDK shape `{download_url, file_id, mime_type, file_name}`. Each leaves the `input` envelope and becomes a top-level property with that exact schema (or an array of it), the tool's `_meta[\"openai/fileParams\"]` names them, and a call's values are checked for that shape and put back into the action input."
    ]
  ]

  @tool_schema [
    name: [type: :atom, required: true],
    resource: [type: {:spark, Ash.Resource}, required: false],
    action: [type: :atom, required: true],
    action_parameters: [
      type:
        {:list,
         {:or,
          [
            :atom,
            {:tuple,
             [
               {:literal, :result_type},
               {:list, {:in, [:run_query, :count, :exists, :aggregate]}}
             ]}
          ]}},
      required: false,
      doc:
        "A list of action specific parameters to allow for the underlying action. Only relevant for reads, and defaults to allowing `[:sort, :offset, :limit, :result_type, :filter]`. Paginated actions always expose their page controls (`offset`, and/or `after`/`before` keyset cursors) regardless of this list, since the returned page hands back the value to pass for the next page. `:result_type` may also be given as `result_type: [:count]` to restrict which result types are offered; `:run_query` is always included."
    ],
    full_filter_schema?: [
      type: :boolean,
      default: false,
      doc:
        "Whether to generate the full JSON schema for the `filter` parameter of read actions. When `false` (the default), the filter is a free-form object whose shape is explained in the parameter description, keeping the tool definition much smaller. Set to `true` when you need a fully-specified schema, e.g. for strict/grammar-constrained tool calling."
    ],
    load: [
      type: :any,
      default: [],
      doc: """
      A list of relationships and calculations to load, or an anonymous function/1.

      Note that loaded fields can include private attributes, which will then be included in the tool's response. However, private attributes cannot be used for filtering, sorting, or aggregation.

      If a function is provided, it will be called with the tool input (a Map with **String keys**) and must return the final load list, e.g. `load fn input -> [schedule: [date: input["date"]]] end` (use string keys!).
      """
    ],
    load_strict?: [
      type: :boolean,
      default: false,
      doc: """
      Whether to apply the `load` statement strictly.

      When `true`, only the fields listed for a relationship in `load` are selected on that
      relationship, rather than all of its public attributes. This keeps tool responses (and the
      underlying queries) smaller when you only need a few fields of a related record.

      Note that with `load_strict?: true` you must list every field you want alongside any nested
      relationships, e.g. `load: [:title, category: [:name]]`.
      """
    ],
    select: [
      type: {:list, :atom},
      doc: """
      A list of attributes to return for the tool's resource.

      When set, only these attributes are read and included in the tool's response, instead of all
      public attributes. Private attributes may be listed here, which will then be included in the
      response. Note that private attributes still cannot be used for filtering, sorting, or
      aggregation.

      Fields listed in `load` are included in the response in addition to those listed here.
      """
    ],
    async: [type: :boolean, default: true],
    description: [
      type: :string,
      doc: "A description for the tool. Defaults to the action's description."
    ],
    identity: [
      type: :atom,
      default: nil,
      doc:
        "The identity to use for update/destroy actions. Defaults to the primary key. Set to `false` to disable entirely."
    ],
    get_by: [
      type: {:or, [:atom, {:list, :atom}]},
      doc:
        "For read actions, a field or list of fields used to fetch a single record. The fields must be filterable attributes, calculations or aggregates."
    ],
    _meta: [
      type: :any,
      default: %{},
      doc:
        "Optional metadata map for tool integrations. Supports provider-specific extensions like OpenAI metadata. Keys and values should be strings to comply with JSON-RPC serialization."
    ],
    ui: [
      type: {:or, [:atom, :string]},
      doc:
        "The `mcp_ui_resource` name (atom) or a `ui://` URI string for MCP Apps. Shortcut for setting `_meta.ui.resourceUri`. When an atom is given, the URI is resolved from the matching `mcp_ui_resource` declaration."
    ]
  ]

  @mcp_resource_schema [
    name: [type: :atom, required: true],
    title: [
      type: :string,
      required: true,
      doc: "A short, human-readable title for the resource."
    ],
    description: [
      type: :string,
      doc:
        "A description of the resource. This is important for LLM to determine what the resource is and when to call it. Defaults to the Action's description if not provided."
    ],
    uri: [
      type: :string,
      required: true,
      doc: "The URI where the resource can be accessed."
    ],
    mime_type: [
      type: :string,
      default: "text/plain",
      doc: "The MIME type of the resource, e.g. 'application/json', 'image/png', etc."
    ],
    resource: [type: {:spark, Ash.Resource}, required: true],
    action: [type: :atom, required: true]
  ]

  @full_text_schema [
    name: [
      type: :atom,
      default: :full_text_vector,
      doc: "The name of the attribute to store the text vector in"
    ],
    used_attributes: [
      type: {:list, :atom},
      doc: "If set, a vector is only regenerated when these attributes are changed"
    ],
    text: [
      type: {:fun, 1},
      required: true,
      doc:
        "A function or expr that takes a list of records and computes a full text string that will be vectorized. If given an expr, use `atomic_ref` to refer to new values, as this is set as an atomic update."
    ]
  ]

  @full_text %Spark.Dsl.Entity{
    name: :full_text,
    imports: [Ash.Expr],
    target: AshAi.FullText,
    identifier: :name,
    schema: @full_text_schema
  }

  @vectorize %Spark.Dsl.Section{
    name: :vectorize,
    entities: [
      @full_text
    ],
    schema: [
      attributes: [
        type: :keyword_list,
        doc:
          "A keyword list of attributes to vectorize, and the name of the attribute to store the vector in",
        default: []
      ],
      strategy: [
        type: {:one_of, [:after_action, :manual, :ash_oban, :ash_oban_manual]},
        default: :after_action,
        doc:
          "How to compute the vector. Currently supported strategies are `:after_action`, `:manual`, and `:ash_oban`."
      ],
      define_update_action_for_manual_strategy?: [
        type: :boolean,
        default: true,
        doc:
          "If true, an `ash_ai_update_embeddings` update action will be defined, which will automatically update the embeddings when run."
      ],
      ash_oban_trigger_name: [
        type: :atom,
        default: :ash_ai_update_embeddings,
        doc:
          "The name of the AshOban-trigger that will be run in order to update the record's embeddings. Defaults to `:ash_ai_update_embeddings`."
      ],
      embedding_model: [
        type: {:spark_behaviour, AshAi.EmbeddingModel},
        required: true
      ]
    ]
  }

  @tool_argument %Spark.Dsl.Entity{
    name: :argument,
    schema: @tool_argument_schema,
    describe: "An argument to be passed to the tool.",
    target: AshAi.Tool.Argument,
    args: [:name, :type]
  }

  @tool %Spark.Dsl.Entity{
    name: :tool,
    describe: """
    Expose an Ash action as a tool that can be called by LLMs.

    Tools allow LLMs to interact with your application by calling specific actions on resources.
    Only public attributes can be used for filtering, sorting, and aggregation, but the `load`
    option allows including private attributes in the response data.
    """,
    examples: [
      ~s(tool :list_artists, Artist, :read),
      ~s(tool :get_artist_by_id, Artist, :read, get_by: :id),
      ~s(tool :create_artist, Artist, :create, description: "Create a new artist"),
      ~s(tool :update_artist, Artist, :update, identity: :id, load: [:albums]),
      ~s(tool :list_artists, Artist, :read, load: [albums: [:title]], load_strict?: true),
      ~s(tool :list_artists, Artist, :read, select: [:name]),
      """
      tool :list_artists, Artist, :read do
        load fn input ->
          [schedule: [date: input["date"]]] # Use string keys!
        end
      end
      """,
      ~s|tool :get_board, Board, :read, _meta: %{"openai/outputTemplate" => "ui://widget/kanban-board.html", "openai/toolInvocation/invoking" => "Preparing the board…", "openai/toolInvocation/invoked" => "Board ready."}|,
      ~s(tool :list_artists, Artist, :read, ui: "ui://artists/list.html")
    ],
    target: AshAi.Tool,
    schema: @tool_schema ++ @blended_tool_schema,
    args: [:name, {:optional, :resource}, :action],
    entities: [
      arguments: [@tool_argument]
    ]
  }

  # BLENDED-008: from ash_hyperlang lib/ash_hyperlang/domain.ex:140
  @delivery_hints %Spark.Dsl.Entity{
    name: :delivery_hints,
    target: AshAi.Expose.DeliveryHints,
    args: [:callback],
    describe: """
    A per-resource callback returning a list of hint maps (`%{note: ..., action: ..., args: ...}`)
    attached to MCP `tools/call` results for tools on the exposed resource, under
    `_meta["hyperbob/delivery_hints"]`.
    """,
    examples: [
      """
      expose MyApp.Blog.Post do
        delivery_hints fn
          %{result: %{id: id}} -> [%{note: "Comment on it", action: :comment, args: %{post_id: id}}]
          _context -> nil
        end

        interface :comment
      end
      """
    ],
    schema: [
      # BLENDED-015: `fun | {module, opts}`, as a generic action's `run`.
      callback: [
        type: {:spark_function_behaviour, AshAi.DeliveryHints, {AshAi.DeliveryHints.Function, 1}},
        required: true,
        doc:
          "A function receiving `%{tool:, resource:, action:, arguments:, result:}` and returning a list of hint maps or `nil`, or a module implementing `AshAi.DeliveryHints` (`module` or `{module, opts}`)."
      ]
    ]
  }

  # BLENDED-001: from ash_hyperlang lib/ash_hyperlang/domain.ex:173
  @interface %Spark.Dsl.Entity{
    name: :interface,
    target: AshAi.Expose.Interface,
    args: [:name],
    # No Spark `identifier`: Spark's nested uniqueness check would also compare every `tool`
    # in the section by name at compile time, changing upstream's runtime duplicate error.
    # `AshAi.Verifiers.VerifyExposures` checks interface names instead.
    describe: """
    Exposes one domain code interface (`define`) as a tool named after the interface, calling
    the action behind that `define`.
    """,
    examples: [
      ~s(interface :list_posts, description: "Lists posts visible to the caller.", example: ~s|{"input": {}}|)
    ],
    schema:
      [
        name: [
          type: :atom,
          required: true,
          doc: "The domain code interface to expose. The tool uses this name verbatim."
        ],
        description: [
          type: :string,
          doc: "Agent-facing documentation. Overrides the underlying action description."
        ]
      ] ++ @blended_tool_schema
  }

  # BLENDED-001: from ash_hyperlang lib/ash_hyperlang/domain.ex:233
  @expose %Spark.Dsl.Entity{
    name: :expose,
    target: AshAi.Expose,
    args: [:resource],
    identifier: :resource,
    transform: {AshAi.Expose, :transform, []},
    describe: """
    Groups the code interfaces of one resource that are exposed as tools. Domain-level only;
    each `interface` must match a `define` on that resource in the domain `resources` block.
    """,
    examples: [
      """
      expose MyApp.Blog.Post do
        interface :list_posts
        interface :create_post, description: "Creates a blog post."
      end
      """
    ],
    entities: [delivery_hints: [@delivery_hints], interfaces: [@interface]],
    schema: [
      resource: [
        type: {:spark, Ash.Resource},
        required: true,
        doc: "The Ash resource whose domain code interfaces are exposed."
      ]
    ]
  }

  @tools %Spark.Dsl.Section{
    name: :tools,
    schema: [
      # BLENDED-012: from ash_hyperlang lib/ash_hyperlang/eval_actions.ex:54
      forbidden_fields: [
        type: {:in, [:hide, :display]},
        doc:
          "How fields hidden by field policies appear in tool results. `:hide` (the default) omits them; `:display` renders `%{opaque: :forbidden}` so a caller can tell a forbidden field apart from an absent one. Resource-level settings win over the domain's."
      ]
    ],
    entities: [
      @tool,
      @expose
    ]
  }

  @mcp_ui_resource_schema [
    name: [type: :atom, required: true],
    uri: [
      type: :string,
      required: true,
      doc: "The `ui://` URI for this resource."
    ],
    html_path: [
      type: :string,
      doc:
        "Path to the HTML file on disk. Read at request time. Exactly one of `html_path` and `page` is required."
    ],
    page: [
      type: :atom,
      doc:
        "A page of the application's UI framework, as the view instead of an HTML file (BLENDED-020). The view's template is the page's client; the page's own actions become app-only tools whose results carry the page's server render. See `AshAi.Page`."
    ],
    title: [
      type: :string,
      doc: "A short, human-readable title. Defaults to the resource name."
    ],
    description: [
      type: :string,
      doc: "A description of the UI resource."
    ],
    csp: [
      type: :keyword_list,
      keys: [
        connect_domains: [type: {:list, :string}],
        resource_domains: [type: {:list, :string}],
        frame_domains: [type: {:list, :string}],
        base_uri_domains: [type: {:list, :string}]
      ],
      doc: "Content Security Policy configuration."
    ],
    permissions: [
      type: :keyword_list,
      keys: [
        camera: [type: :boolean],
        microphone: [type: :boolean],
        geolocation: [type: :boolean],
        clipboard_write: [type: :boolean]
      ],
      doc: "Browser permissions to request for the sandboxed iframe."
    ],
    domain: [
      type: {:or, [:atom, :string]},
      default: :auto,
      doc:
        "Domain for the view's sandbox origin. Defaults to `:auto`, which computes a Claude-compatible domain from the server URL at request time (see `AshAi.Mcp.Server.sandbox_domain/1`). Set to a string to override, or `nil` to omit."
    ],
    prefers_border: [
      type: :boolean,
      doc: "Whether the app prefers a visible border and background from the host."
    ]
  ]

  @mcp_ui_resource %Spark.Dsl.Entity{
    name: :mcp_ui_resource,
    describe: """
    A UI resource for MCP Apps — serves a static HTML file that is rendered in a sandboxed
    iframe by MCP hosts (like Claude Desktop). Link tools to UI resources using the tool's
    `ui:` option or `_meta.ui.resourceUri`.

    See [MCP Apps spec](https://modelcontextprotocol.io/specification/2025-11-25).
    """,
    examples: [
      ~s(mcp_ui_resource :artist_viewer, "ui://artists/viewer.html", html_path: "priv/mcp_apps/artist_viewer.html"),
      ~s(mcp_ui_resource :artist_dashboard, "ui://artists/dashboard.html", html_path: "priv/mcp_apps/artist_dashboard.html", csp: [connect_domains: ["api.example.com"]]),
      ~s(mcp_ui_resource :artist_page, "ui://artists/page", page: MyApp.ArtistPage)
    ],
    target: AshAi.McpUiResource,
    schema: @mcp_ui_resource_schema,
    args: [:name, :uri]
  }

  @mcp_resource %Spark.Dsl.Entity{
    name: :mcp_resource,
    describe: """
    An MCP resource to expose via the Model Context Protocol (MCP).
    MCP Resources are different to Ash Resources. Here they are used to
    respond to LLM models with static or dynamic assets like files, images, or JSON.

    The resource description defaults to the action's description. You can override this
    by providing a `description` option which takes precedence.
    """,
    examples: [
      ~s(mcp_resource :artist_card, "file://info/artist_info.txt", Artist, :artist_info),
      ~s(mcp_resource :artist_card, "file://ui/artist_card.html", Artist, :artist_card, mime_type: "text/html"),
      ~s(mcp_resource :artist_data, "file://data/artist.json", Artist, :to_json, description: "Artist metadata as JSON", mime_type: "application/json")
    ],
    target: AshAi.McpResource,
    schema: @mcp_resource_schema,
    args: [:name, :uri, :resource, :action]
  }

  @mcp_resources %Spark.Dsl.Section{
    name: :mcp_resources,
    entities: [
      @mcp_resource,
      @mcp_ui_resource
    ]
  }

  @doc false
  def sections do
    [@tools, @vectorize, @mcp_resources]
  end
end
