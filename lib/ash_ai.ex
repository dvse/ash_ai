# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi do
  @moduledoc """
  Documentation for `AshAi`.
  """

  defstruct []

  require Logger

  use Spark.Dsl.Extension,
    sections: AshAi.Dsl.sections(),
    imports: [AshAi.Actions],
    transformers: [
      AshAi.Transformers.Vectorize,
      AshAi.Transformers.ResourceTools,
      AshAi.Transformers.McpApps
    ],
    verifiers: [AshAi.Verifiers.McpResourceActionsReturnString, AshAi.Verifiers.VerifyExposures]

  defmodule Tool do
    @moduledoc "An action exposed to LLM agents"
    @type t :: %__MODULE__{}

    defstruct [
      :name,
      :resource,
      :action,
      :load,
      :select,
      :async,
      :domain,
      :identity,
      :get_by,
      :description,
      :action_parameters,
      :arguments,
      :_meta,
      :ui,
      # BLENDED-003..012 (see BLENDED.md)
      :example,
      :blocking?,
      :hints,
      :delivery_hints,
      :forbidden_fields,
      :interface,
      # BLENDED-016/018 (see BLENDED.md)
      :security_schemes,
      file_params: [],
      refine?: true,
      continuation_target?: false,
      annotations: [],
      output_schema?: true,
      full_filter_schema?: false,
      load_strict?: false,
      __spark_metadata__: nil
    ]

    defmodule Argument do
      @moduledoc """
      A struct representing an argument defined in the Tool DSL.
      """
      defstruct [
        :name,
        :type,
        :description,
        :default,
        constraints: [],
        allow_nil?: true,
        __spark_metadata__: nil
      ]
    end

    def has_meta?(%__MODULE__{_meta: meta})
        when not is_nil(meta) and meta != %{},
        do: true

    def has_meta?(_), do: false

    @doc """
    Whether a call to this tool blocks until its result is ready.

    An explicit `blocking?` option wins. Otherwise an action that carries `metadata` (every
    non-generic action) is blocking when it declares `metadata :blocking?` defaulting to `true`
    (or to a zero-arity function returning `true`); a generic action is blocking when it, or
    the interface exposing it, is named `:await`.
    """
    # BLENDED-005: from ash_hyperlang lib/ash_hyperlang/surface.ex:152
    def blocking?(%__MODULE__{blocking?: value}) when is_boolean(value), do: value

    def blocking?(%__MODULE__{action: action, interface: interface}),
      do: blocking_action?(action, interface)

    # BLENDED-005: from ash_hyperlang lib/ash_hyperlang/surface.ex:155
    defp blocking_action?(%{metadata: metadata}, _interface_name) when is_list(metadata) do
      metadata_flag(metadata, :blocking?) == true
    end

    defp blocking_action?(%{name: name}, interface_name)
         when name == :await or interface_name == :await,
         do: true

    defp blocking_action?(_action, _interface_name), do: false

    # The carrier convention of ash_hyperlang `blocking_action?/2`: a declared metadata entry
    # counts as `true` only when its default is `true` or a zero-arity function returning `true`.
    # `nil` means the action does not declare the entry.
    # BLENDED-005/009: from ash_hyperlang lib/ash_hyperlang/surface.ex:156
    defp metadata_flag(metadata, name) do
      case Enum.find(metadata, &(&1.name == name)) do
        nil -> nil
        %{default: default} when is_function(default, 0) -> default.() == true
        %{default: default} -> default == true
      end
    end

    @doc """
    The MCP tool annotations (`title`, `read_only?`, `destructive?`, `idempotent?`,
    `open_world?`) resolved from the `annotations` option, the action's
    `metadata :read_only?`/`metadata :destructive?` declarations, and the action type.
    """
    # BLENDED-009: MCP spec `ToolAnnotations`; carrier pattern from ash_hyperlang
    # lib/ash_hyperlang/surface.ex:155 (action metadata)
    def annotations(%__MODULE__{annotations: annotations, action: action}) do
      annotations = annotations || []
      metadata = Map.get(action, :metadata) || []
      {read_only?, destructive?} = type_annotations(action.type)

      %{
        title: annotations[:title],
        read_only?:
          first_boolean(
            [annotations[:read_only?], metadata_flag(metadata, :read_only?)],
            read_only?
          ),
        destructive?:
          first_boolean(
            [annotations[:destructive?], metadata_flag(metadata, :destructive?)],
            destructive?
          ),
        idempotent?: annotations[:idempotent?] == true,
        open_world?: annotations[:open_world?] == true
      }
    end

    defp first_boolean(values, default) do
      Enum.find(values, default, &is_boolean/1)
    end

    defp type_annotations(:read), do: {true, false}
    defp type_annotations(:create), do: {false, false}
    defp type_annotations(type) when type in [:update, :destroy], do: {false, true}
    defp type_annotations(:action), do: {false, true}

    @doc "The MCP tool title: `annotations[:title]`, else the tool (interface) name."
    def title(%__MODULE__{} = tool) do
      (tool.annotations || [])[:title] || to_string(tool.name)
    end

    @doc """
    Hyperbob `_meta` keys for the tool, merged over the upstream `_meta` map. Keys are only
    present when their flag is set, so tools without them keep upstream's `_meta` exactly.
    """
    # BLENDED-005/006
    def meta(%__MODULE__{} = tool) do
      (tool._meta || %{})
      |> put_flag("hyperbob/blocking", blocking?(tool))
      |> put_flag("hyperbob/continuation_target", tool.continuation_target? == true)
    end

    defp put_flag(meta, key, true), do: Map.put(meta, key, true)
    defp put_flag(meta, _key, false), do: meta

    @doc """
    Resolves the attribute keys used to address a record for update/destroy tools.

    Mirrors the `identity:` tool option so schema generation and execution stay in sync:

      * `false` - no identifier keys (the caller adds no filter / no schema property)
      * `nil` - the resource's primary key (the default)
      * a name - the keys of the named identity
    """
    def identity_keys(_resource, false), do: []

    def identity_keys(resource, nil), do: Ash.Resource.Info.primary_key(resource)

    def identity_keys(resource, name) do
      resource
      |> Ash.Resource.Info.identities()
      |> Enum.find(&(&1.name == name))
      |> case do
        nil ->
          raise ArgumentError,
                "No identity named #{inspect(name)} found on #{inspect(resource)}"

        identity ->
          identity.keys
      end
    end

    @doc false
    # Raises ArgumentError if a field is not usable as a lookup.
    def get_by_fields(resource, get_by) do
      get_by
      |> List.wrap()
      |> Enum.map(fn field_name ->
        case validate_get_by_field(resource, field_name) do
          {:ok, field} -> field
          {:error, message} -> raise ArgumentError, message
        end
      end)
    end

    @doc false
    # `resource` may be a resource module or its Spark.Dsl state, so this can run while the
    # resource itself is being compiled.
    def validate_get_by_field(resource, field_name) do
      case Ash.Resource.Info.field(resource, field_name) do
        %struct{}
        when struct in [
               Ash.Resource.Relationships.BelongsTo,
               Ash.Resource.Relationships.HasOne,
               Ash.Resource.Relationships.HasMany,
               Ash.Resource.Relationships.ManyToMany
             ] ->
          {:error, "cannot `get_by` on the relationship `#{inspect(field_name)}`"}

        %{filterable?: false} ->
          {:error, "`#{inspect(field_name)}` is not filterable, so it cannot be used in `get_by`"}

        nil ->
          {:error,
           "`#{inspect(field_name)}` is not a valid attribute, calculation or aggregate on #{inspect(resource_module(resource))}"}

        field ->
          {:ok, field}
      end
    end

    defp resource_module(resource) when is_atom(resource), do: resource

    defp resource_module(dsl_state),
      do: Spark.Dsl.Transformer.get_persisted(dsl_state, :module, dsl_state)
  end

  defmodule McpResource do
    @moduledoc """
    An MCP resource to expose via the Model Context Protocol (MCP).

    MCP resources provide LLMs with access to static or dynamic content like UI components,
    data files, or images. Unlike tools which perform actions, resources return content that
    the LLM can read and reference.

    ## Example

    ```elixir
    defmodule MyApp.Blog do
      use Ash.Domain, extensions: [AshAi]

      mcp_resources do
        # Description inherited from :render_card action
        mcp_resource :post_card, "file://ui/post_card.html", Post, :render_card,
          mime_type: "text/html"

        # Custom description overrides action description
        mcp_resource :post_data, "file://data/post.json", Post, :to_json,
          description: "JSON metadata including author, tags, and timestamps",
          mime_type: "application/json"
      end
    end
    ```

    The action is called when an MCP client requests the resource, and its return value
    (which must be a string) is sent to the client with the specified MIME type.

    ## Description Behavior

    Resource descriptions default to the action's description. You can provide a custom
    `description` option in the DSL which takes precedence over the action description.
    This helps LLMs understand when to use each resource.
    """
    @type t :: %__MODULE__{
            name: atom(),
            resource: Ash.Resource.t(),
            action: atom() | Ash.Resource.Actions.Action.t(),
            domain: module() | nil,
            title: String.t(),
            description: String.t(),
            uri: String.t(),
            mime_type: String.t()
          }

    defstruct [
      :name,
      :resource,
      :action,
      :domain,
      :title,
      :description,
      :uri,
      :mime_type,
      __spark_metadata__: nil
    ]
  end

  defmodule McpUiResource do
    @moduledoc """
    A UI resource for MCP Apps (Model Context Protocol Apps extension).

    UI resources serve static HTML files that are rendered in sandboxed iframes by MCP hosts
    (like Claude Desktop). They are linked to tools via `_meta.ui.resourceUri` and provide
    interactive interfaces for tool results.

    ## Example

        mcp_resources do
          mcp_ui_resource :estimates_list, "ui://estimates/list.html",
            html_path: "priv/mcp_apps/estimates.html"

          mcp_ui_resource :dashboard, "ui://dashboard.html",
            html_path: "priv/mcp_apps/dashboard.html",
            csp: [connect_domains: ["api.example.com"]],
            permissions: [camera: true]
        end

    The HTML file at `html_path` is read at request time and returned with MIME type
    `text/html;profile=mcp-app`.

    See [MCP Apps spec](https://modelcontextprotocol.io/specification/2025-11-25).
    """

    @mime_type "text/html;profile=mcp-app"

    @type t :: %__MODULE__{
            name: atom(),
            uri: String.t(),
            html_path: String.t() | nil,
            page: module() | nil,
            title: String.t() | nil,
            description: String.t() | nil,
            csp: keyword() | nil,
            permissions: keyword() | nil,
            domain: :auto | String.t() | nil,
            prefers_border: boolean() | nil
          }

    defstruct [
      :name,
      :uri,
      :html_path,
      :page,
      :title,
      :description,
      :csp,
      :permissions,
      :domain,
      :prefers_border,
      __spark_metadata__: nil
    ]

    @doc "Returns the fixed MIME type for MCP App UI resources."
    def mime_type, do: @mime_type
  end

  defmodule Expose do
    @moduledoc """
    A resource whose domain code interfaces are exposed as tools (BLENDED-001).

    ```elixir
    tools do
      expose MyApp.Blog.Post do
        interface :list_posts, example: ~s|{"input": {}}|
        interface :publish_post, annotations: [destructive?: false]
      end
    end
    ```

    Each `interface` becomes one tool named after the interface, calling the action behind
    the matching `define` in the domain `resources` block. Interfaces over non-public actions
    are skipped.
    """

    # BLENDED-001: from ash_hyperlang lib/ash_hyperlang/domain.ex:47
    defstruct [
      :resource,
      :delivery_hints,
      :__identifier__,
      interfaces: [],
      __spark_metadata__: nil
    ]

    @type t :: %__MODULE__{}

    defmodule Interface do
      @moduledoc "One code interface exposed as a tool (BLENDED-001)."
      # BLENDED-001: from ash_hyperlang lib/ash_hyperlang/domain.ex:1
      defstruct [
        :name,
        :description,
        :example,
        :blocking?,
        :hints,
        :__identifier__,
        :security_schemes,
        file_params: [],
        refine?: true,
        continuation_target?: false,
        annotations: [],
        output_schema?: true,
        __spark_metadata__: nil
      ]

      @type t :: %__MODULE__{}
    end

    defmodule DeliveryHints do
      @moduledoc "A resource-level delivery hint callback (BLENDED-008)."
      # BLENDED-008: from ash_hyperlang lib/ash_hyperlang/domain.ex:33
      defstruct [:callback, :__identifier__, __spark_metadata__: nil]

      @type t :: %__MODULE__{}
    end

    @doc false
    # BLENDED-008: from ash_hyperlang lib/ash_hyperlang/domain.ex:325 (`set_expose_name/1`)
    def transform(%__MODULE__{} = expose) do
      delivery_hints =
        case expose.delivery_hints do
          [%DeliveryHints{callback: callback} | _rest] -> callback
          _other -> nil
        end

      {:ok, %{expose | delivery_hints: delivery_hints}}
    end
  end

  defmodule FullText do
    @moduledoc "A section that defines how complex vectorized columns are defined"
    defstruct [
      :used_attributes,
      :text,
      :__identifier__,
      name: :full_text_vector,
      __spark_metadata__: nil
    ]
  end

  defmodule Options do
    @moduledoc false
    use Spark.Options.Validator,
      schema: [
        actions: [
          type:
            {:wrap_list,
             {:tuple, [{:spark, Ash.Resource}, {:or, [{:list, :atom}, {:literal, :*}]}]}},
          doc: """
          A set of {Resource, [:action]} pairs, or `{Resource, :*}` for all actions. Defaults to everything. If `tools` is also set, both are applied as filters.
          """
        ],
        tools: [
          type: {:or, [:boolean, {:wrap_list, :atom}]},
          default: true,
          doc: """
           A list of tool names. If not set. Defaults to everything. If `actions` is also set, both are applied as filters.
          """
        ],
        mcp_resources: [
          type: {:or, [{:wrap_list, :atom}, {:literal, :*}]},
          doc: """
          A list of MCP resource names to expose, or `:*` for all. If not set, defaults to everything.
          """
        ],
        exclude_actions: [
          type: {:wrap_list, {:tuple, [{:spark, Ash.Resource}, :atom]}},
          doc: """
          A set of {Resource, :action} pairs, or `{Resource, :*}` to be excluded from the added actions.
          """
        ],
        actor: [
          type: :any,
          doc: "The actor performing any actions."
        ],
        tenant: [
          type: {:protocol, Ash.ToTenant},
          doc: "The tenant to use for the action."
        ],
        messages: [
          type: {:list, :map},
          default: [],
          doc: """
          Used to provide conversation history.
          """
        ],
        context: [
          type: :map,
          default: %{},
          doc: """
          Context passed to each action invocation.
          """
        ],
        otp_app: [
          type: :atom,
          doc: "If present, allows discovering resource actions automatically."
        ],
        system_prompt: [
          type: {:or, [{:fun, 1}, {:literal, :none}]},
          doc: """
          A system prompt that takes the provided options and returns a system prompt.

          You will want to include something like the actor's id if you are chatting as an
          actor.
          """
        ],
        on_tool_start: [
          type: {:fun, 1},
          required: false,
          doc: """
          A callback function that is called when a tool execution starts.

          Receives an `AshAi.ToolStartEvent` struct with the following fields:
          - `:tool_name` - The name of the tool being called
          - `:action` - The action being performed
          - `:resource` - The resource the action is on
          - `:arguments` - The arguments passed to the tool
          - `:actor` - The actor performing the action
          - `:tenant` - The tenant context

          Example:
          ```
          on_tool_start: fn %AshAi.ToolStartEvent{} = event ->
            IO.puts("Starting tool: \#{event.tool_name}")
          end
          ```
          """
        ],
        on_tool_end: [
          type: {:fun, 1},
          required: false,
          doc: """
          A callback function that is called when a tool execution completes.

          Receives an `AshAi.ToolEndEvent` struct with the following fields:
          - `:tool_name` - The name of the tool
          - `:result` - The result of the tool execution (either {:ok, ...} or {:error, ...})

          Example:
          ```
          on_tool_end: fn %AshAi.ToolEndEvent{} = event ->
            IO.puts("Completed tool: \#{event.tool_name}")
          end
          ```
          """
        ],
        strict: [
          type: :boolean,
          default: true,
          doc: """
          Whether to use strict schema mode when generating tool parameter schemas.

          When `true` (the default), applies OpenAI-compatible strict schema transformation: all objects get
          `additionalProperties: false`, all properties are included in `required`,
          and optional properties are wrapped in `anyOf: [null, type]`.

          Set to `false` when using providers that do not support this schema format.
          For example, Google Gemini rejects `additionalProperties` in function declarations.

          When `false`, `additionalProperties` is stripped from the schema and no
          `anyOf` null-wrapping is applied.
          """
        ],
        model: [
          type: :any,
          default: "openai:gpt-4o-mini",
          doc: """
          The LLM model specification used by ReqLLM.

          Can be:
          - a string (e.g. `"openai:gpt-4o-mini"`)
          - a tuple accepted by ReqLLM (e.g. `{:anthropic, [id: "claude-sonnet-4-5"]}`)
          - a function returning either format
          """
        ],
        req_llm: [
          type: :atom,
          default: ReqLLM,
          doc: """
          The ReqLLM module to use. Defaults to `ReqLLM`.
          Useful for tests with a mock ReqLLM module.
          """
        ],
        req_llm_opts: [
          type: :keyword_list,
          default: [],
          doc: """
          Additional options passed through to ReqLLM requests.

          AshAi still controls the final `:tools` value used for tool-calling.
          """
        ],
        extra_tools: [
          type: {:list, :any},
          default: [],
          doc: """
          Additional ReqLLM tools to expose alongside AshAi-discovered tools.

          Accepts either:
          - `%ReqLLM.Tool{}`
          - `{%ReqLLM.Tool{}, callback}` where `callback` is `fn args, context -> ... end`
          """
        ],
        max_iterations: [
          type: {:or, [:pos_integer, {:literal, :infinity}]},
          default: 10,
          doc: """
          Maximum number of tool-calling iterations before terminating.

          Set to `:infinity` to disable iteration limits.
          """
        ]
      ]
  end

  @doc """
  Returns ReqLLM tools for the given options.
  """
  def list_tools(opts) when is_list(opts), do: list_tools(Options.validate!(opts))
  def list_tools(opts), do: AshAi.Tools.list(opts)

  @doc """
  Returns `{tools, registry}` for ReqLLM tool-calling flows.
  """
  def build_tools_and_registry(opts) when is_list(opts) do
    opts
    |> Options.validate!()
    |> build_tools_and_registry()
  end

  def build_tools_and_registry(opts), do: AshAi.Tools.build_tools_and_registry(opts)

  if Code.ensure_loaded?(ReqLLM) do
    alias ReqLLM.Context

    @doc """
    Interactive IEx chat loop powered by ReqLLM.
    """
    def iex_chat(opts \\ []) do
      validated_opts = Options.validate!(opts)

      base_messages =
        case validated_opts.system_prompt do
          :none ->
            []

          nil ->
            [
              Context.system("""
              You are a helpful assistant.
              Your purpose is to operate the application on behalf of the user.
              """)
            ]

          system_prompt ->
            [Context.system(system_prompt.(validated_opts))]
        end

      run_iex_loop(base_messages, opts)
    end

    defp run_iex_loop(messages, opts) do
      case AshAi.ToolLoop.run(messages, opts) do
        {:ok, %AshAi.ToolLoop.Result{messages: updated_messages, final_text: final_text}} ->
          if final_text != "" do
            IO.puts(final_text)
          end

          case get_user_message() do
            :eof ->
              :ok

            user_message ->
              run_iex_loop(updated_messages ++ [Context.user(user_message)], opts)
          end

        {:error, error} ->
          raise "Something went wrong:\n #{inspect(error)}"
      end
    end

    defp get_user_message do
      case Mix.shell().prompt("> ") do
        nil -> :eof
        "" -> get_user_message()
        "\n" -> get_user_message()
        message -> message
      end
    end
  else
    def iex_chat(_opts \\ []), do: AshAi.Dependencies.require_req_llm!("`AshAi.iex_chat/1`")
  end

  @doc false

  def exposed_mcp_action_resources(opts) when is_list(opts) do
    exposed_mcp_action_resources(Options.validate!(opts))
  end

  def exposed_mcp_action_resources(opts) do
    opts
    |> resolve_domains()
    |> Enum.flat_map(fn domain ->
      domain
      |> AshAi.Info.mcp_action_resources()
      |> Enum.filter(fn mcp_resource ->
        valid_mcp_resource(mcp_resource, opts.mcp_resources, opts.actions, opts.exclude_actions)
      end)
      |> Enum.map(fn mcp_resource ->
        action = Ash.Resource.Info.action(mcp_resource.resource, mcp_resource.action)

        %{
          mcp_resource
          | domain: domain,
            action: action,
            description: mcp_resource.description || action.description
        }
      end)
    end)
  end

  @doc false
  def exposed_mcp_ui_resources(opts) when is_list(opts) do
    exposed_mcp_ui_resources(Options.validate!(opts))
  end

  def exposed_mcp_ui_resources(opts) do
    opts
    |> resolve_domains()
    |> Enum.flat_map(fn domain ->
      domain
      |> AshAi.Info.mcp_ui_resources()
      |> Enum.filter(fn ui_resource ->
        case opts.mcp_resources do
          nil -> true
          :* -> true
          [:*] -> true
          [] -> false
          list when is_list(list) -> ui_resource.name in list
        end
      end)
    end)
  end

  defp resolve_domains(opts) do
    if !opts.otp_app and !opts.actions do
      raise "Must specify `otp_app` if you do not specify `actions`"
    end

    if opts.actions do
      opts.actions
      |> Enum.map(fn {resource, _actions} ->
        domain = Ash.Resource.Info.domain(resource)

        if !domain do
          raise "Cannot use an ash resource that does not have a domain"
        end

        domain
      end)
      |> Enum.uniq()
    else
      Application.get_env(opts.otp_app, :ash_domains) || []
    end
  end

  defp valid_mcp_resource(mcp_resource, allowed_mcp_resources, allowed_actions, exclude_actions) do
    # If mcp_resources filter is specified (including empty list), check membership
    passes_mcp_resources_filter =
      case allowed_mcp_resources do
        [:*] -> true
        :* -> true
        nil -> true
        [] -> false
        list when is_list(list) -> Enum.member?(list, mcp_resource.name)
      end

    # Check if actions filter is specified
    passes_actions_filter =
      if allowed_actions && allowed_actions != [] do
        Enum.any?(allowed_actions, fn
          {resource, :*} ->
            mcp_resource.resource == resource

          {resource, actions} when is_list(actions) ->
            mcp_resource.resource == resource && mcp_resource.action in actions
        end)
      else
        true
      end

    # Check if this is in the exclude list
    is_excluded =
      if exclude_actions && exclude_actions != [] do
        Enum.any?(exclude_actions, fn {resource, action} ->
          mcp_resource.resource == resource && mcp_resource.action == action
        end)
      else
        false
      end

    passes_mcp_resources_filter && passes_actions_filter && !is_excluded
  end

  def exposed_tools(opts) when is_list(opts) do
    exposed_tools(Options.validate!(opts))
  end

  def exposed_tools(opts) do
    if opts.tools in [false, []] do
      []
    else
      if opts.actions do
        Enum.flat_map(opts.actions, fn
          {resource, actions} ->
            tools = tools_for_resource(resource)

            if !Enum.any?(tools, fn tool ->
                 actions == :* || tool.action.name in actions
               end) do
              raise "Cannot use an action that is not exposed as a tool"
            end

            if actions == :* do
              tools
            else
              tools
              |> Enum.filter(&(&1.action.name in actions))
            end
        end)
      else
        if !opts.otp_app do
          raise "Must specify `otp_app` if you do not specify `actions`"
        end

        for domain <- Application.get_env(opts.otp_app, :ash_domains) || [],
            tool <- tools_for_domain(domain) do
          tool
        end
      end
    end
    |> Enum.uniq()
    |> then(fn tools ->
      if is_list(opts.exclude_actions) do
        Enum.reject(tools, fn tool ->
          {tool.resource, tool.action.name} in opts.exclude_actions
        end)
      else
        tools
      end
    end)
    |> then(fn tools ->
      case opts.tools do
        true -> tools
        false -> []
        allowed_tools -> Enum.filter(tools, &(&1.name in allowed_tools))
      end
    end)
    |> Enum.filter(
      &can?(
        opts.actor,
        &1.domain,
        &1.resource,
        &1.action,
        opts.tenant
      )
    )
  end

  defp tools_for_domain(domain) do
    domain_forbidden_fields = forbidden_fields_setting(domain, :hide)

    domain_tools =
      domain
      |> AshAi.Info.action_tools()
      |> Enum.concat(AshAi.Info.interface_tools(domain))
      |> attach_tool_runtime_details(domain, domain_forbidden_fields)

    resource_tools =
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.flat_map(fn resource ->
        # BLENDED-012: a resource-level setting wins over the domain's.
        forbidden_fields = forbidden_fields_setting(resource, domain_forbidden_fields)

        resource
        |> AshAi.Info.action_tools()
        |> attach_tool_runtime_details(domain, forbidden_fields)
      end)

    domain_tools
    |> Enum.concat(resource_tools)
    |> attach_delivery_hints(domain)
    |> ensure_unique_tool_names!(domain)
  end

  defp tools_for_resource(resource) do
    domain = Ash.Resource.Info.domain(resource)

    if !domain do
      raise "Cannot use an ash resource that does not have a domain"
    end

    domain
    |> tools_for_domain()
    |> Enum.filter(&(&1.resource == resource))
  end

  defp attach_tool_runtime_details(tools, domain, forbidden_fields) do
    Enum.map(tools, fn tool ->
      %{
        tool
        | domain: domain,
          action: Ash.Resource.Info.action(tool.resource, tool.action),
          forbidden_fields: forbidden_fields
      }
    end)
  end

  defp forbidden_fields_setting(dsl, fallback) do
    case AshAi.Info.tools_forbidden_fields(dsl) do
      {:ok, value} -> value
      :error -> fallback
    end
  end

  # BLENDED-008: an `expose` block's `delivery_hints` apply to every tool on that resource.
  defp attach_delivery_hints(tools, domain) do
    hints_by_resource =
      domain
      |> AshAi.Info.exposes()
      |> Enum.filter(& &1.delivery_hints)
      |> Map.new(&{&1.resource, &1.delivery_hints})

    Enum.map(tools, fn tool ->
      %{tool | delivery_hints: Map.get(hints_by_resource, tool.resource)}
    end)
  end

  defp ensure_unique_tool_names!(tools, domain) do
    duplicates =
      tools
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)
      |> Enum.sort()

    case duplicates do
      [] ->
        tools

      names ->
        raise ArgumentError, """
        Duplicate tool names found in #{inspect(domain)}: #{Enum.join(names, ", ")}.

        Tool names must be unique per domain across:
        - domain-level `tools do ... end`
        - resource-level `tools do ... end`
        - domain-level `expose ... interface` entries
        """
    end
  end

  def has_vectorize_change?(%Ash.Changeset{} = changeset) do
    full_text_attrs =
      AshAi.Info.vectorize(changeset.resource) |> Enum.flat_map(& &1.used_attributes)

    vectorized_attrs =
      AshAi.Info.vectorize_attributes!(changeset.resource)
      |> Enum.map(fn {attr, _} -> attr end)

    Enum.any?(vectorized_attrs ++ full_text_attrs, fn attr ->
      Ash.Changeset.changing_attribute?(changeset, attr)
    end)
  end

  @doc false
  # BLENDED-020: also the pre-check of a page view's generated tools.
  def can?(actor, domain, resource, action, tenant) do
    if Enum.empty?(Ash.Resource.Info.authorizers(resource)) do
      true
    else
      Ash.can?({resource, action}, actor,
        tenant: tenant,
        domain: domain,
        context: %{private: %{ash_ai_pre_check?: true}},
        maybe_is: true,
        run_queries?: false,
        pre_flight?: false
      )
    end
  rescue
    e ->
      Logger.error("""
      Error raised while checking permissions for #{inspect(resource)}.#{action.name}

      When checking permissions, we check the action using an empty input.
      Your action should be prepared for this.

      For create/update/destroy actions, you may need to add `only_when_valid?: true`
      to the changes, for other things, you may want to check validity of the changeset,
      query or action input.

      #{Exception.format(:error, e, __STACKTRACE__)}
      """)

      false
  end
end
