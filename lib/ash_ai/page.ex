# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Page do
  @moduledoc """
  A page as an MCP Apps view (BLENDED-020).

  `mcp_ui_resource :name, "ui://…", page: MyApp.SomePage` serves a page of the application's UI
  framework instead of an HTML file. Everything else is upstream ash_ai:

    * **The template.** `resources/read` answers with the page's client document, which the
      framework renders (`c:document/2`). It holds no user data.
    * **The page's actions are tools.** Every action the page's view binds (`c:actions/1`)
      becomes an ordinary tool on its resource and action, named `<resource>_<action>` in snake
      case, with `_meta.ui.resourceUri` naming the view and `_meta.ui.visibility: ["app"]`, so
      the view may call it and the model is never offered it. One more app-only tool, named after
      the page resource, opens the page (its framework mount) and returns it.
    * **Results carry the page.** A call of any tool whose `_meta.ui.resourceUri` names a page
      view (the author's linked tool, or a generated one) runs as usual, then the page is rendered
      for the caller (`c:render/3`) and put in the result's `_meta` under `"ash_ai/page"`. That is
      view-only data (`window.openai.toolResponseMetadata`); `structuredContent` stays the action's
      own result.
    * **The page session is the caller's.** A page's rows are keyed by a session. The session of
      a call is derived from the caller's actor and the page (`session_id/2`), never taken from
      the caller, and handed to the framework (`c:session/2`) as the Ash context and the inputs it
      owns. A call without an actor is refused.
    * **A view holds a live presentation, as a browser tab does.** Every generated tool (the
      open tool and each bound action's) declares an optional top-level argument `presentation`
      beside `input` (a string of at most 128 characters): the opaque handle of the view's live
      presentation on the server, as the page last returned it. Strict hosts forward only a
      tool's name and declared arguments, so the handle travels in a declared argument. It is
      never a credential (the session still comes from the caller's actor) and never reaches the
      action: it is taken out of the arguments before the session's inputs are filled and given
      to the framework, as `:presentation` of the scope (`c:mount/3`, `c:render/3`) and of the
      call (`c:run/4`), nil when absent. A render may answer the handle to use next as its
      frame's `"presentation"`, which reaches the view unchanged in `_meta["ash_ai/page"]`. One
      more app-only tool per page, `<open tool>__close`, takes `presentation` (required) and calls
      the framework's optional `c:close/3`, answering "Done.".

  The framework is found through the page resource's Spark extensions: the first extension that
  exports `mcp_page_adapter/0` names the module implementing this behaviour. AshAi depends on no
  UI framework.
  """

  @typedoc """
  What the framework is told when rendering:

    * `:actor`, `:tenant`, `:context` — the request's, with the session's context merged in;
    * `:params` — mount parameters (the linked tool's input fields, by name);
    * `:errors` — error texts of the call that preceded the render;
    * `:resource` — the `%AshAi.McpUiResource{}`;
    * `:presentation` — the view's live presentation handle the call carried, or nil.
  """
  @type scope :: %{
          required(:actor) => term(),
          required(:tenant) => term(),
          required(:context) => map(),
          required(:params) => map(),
          required(:errors) => [String.t()],
          required(:resource) => AshAi.McpUiResource.t(),
          required(:presentation) => String.t() | nil
        }

  @typedoc """
  One binding of the rendered page: the action a DOM event runs.

    * `:resource`, `:action` — the action (it must be one of `c:actions/1`);
    * `:arguments` — the action inputs the binding fixes;
    * `:event` — action inputs taken from the DOM event, as `%{input => event_field}`;
    * `:accept` — the input names the action takes (the view keeps only these after merging the
      DOM event's fields);
    * `:bound_field` — an input that takes the event's `value`, if any;
    * `:target` — `:page` (the session's own page row) or `{:row, primary_key_map}`.
  """
  @type binding :: %{
          required(:resource) => module(),
          required(:action) => atom(),
          required(:arguments) => map(),
          required(:accept) => [String.t()],
          required(:bound_field) => String.t() | nil,
          required(:target) => :page | {:row, map()}
        }

  @doc "The view's template: the page's client document, the same for every caller."
  @callback document(page :: module(), info :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "The actions the page's view binds, as `{resource, action}`."
  @callback actions(page :: module()) :: [{module(), atom()}]

  @doc """
  What the framework needs for a session: the Ash context to run under, and the inputs the
  session owns on the page resource (e.g. its key), filled by the server and hidden from callers.
  """
  @callback session(page :: module(), session_id :: String.t()) :: %{
              context: map(),
              inputs: map()
            }

  @doc """
  Mount (idempotently) and render the page for a session. `{:ok, frame}` where `frame` is a JSON
  map the template applies, with `"bindings"` as `%{key => binding}`. The frame may carry
  `"presentation"`, the handle the view passes on its next calls; it reaches the view unchanged.
  """
  @callback render(page :: module(), session_id :: String.t(), scope()) ::
              {:ok, map()} | {:error, String.t()}

  @doc """
  Mount the page row of a session (idempotently), before an action runs on it. Optional: a
  framework whose `c:render/3` is the only mount leaves it out.
  """
  @callback mount(page :: module(), session_id :: String.t(), scope()) ::
              :ok | {:error, String.t()}

  @doc """
  Run a page action for a session, as the framework's own dispatch does (optional). A framework
  whose page rows are reachable only through its dispatch boundary (a session key the caller may
  not filter by) answers here; one that leaves page actions to ordinary tool execution leaves it
  out. `call` names the tool's `resource`, `action` and its `arguments` (upstream's tool argument
  shape: `"input"` and top-level identity values), and the view's `presentation` (or nil).
  `:ok` or `{:error, text}`.
  """
  @callback run(page :: module(), session_id :: String.t(), call :: map(), scope()) ::
              :ok | {:error, String.t()}

  @doc """
  Close a view's live presentation of a session (optional), when the view's close tool is
  called. Without it the close tool answers "Done." and does nothing.
  """
  @callback close(page :: module(), session_id :: String.t(), presentation :: String.t()) ::
              :ok | {:error, String.t()}

  @optional_callbacks mount: 3, run: 4, close: 3

  @meta_key "ash_ai/page"
  @visibility_app %{"visibility" => ["app"]}
  @presentation "presentation"
  @presentation_max_length 128
  @presentation_description "The view's live presentation, as the page last returned it."

  @doc "The result `_meta` key that carries the page."
  def meta_key, do: @meta_key

  @doc "Whether a UI resource is a page."
  def page?(%AshAi.McpUiResource{page: page}) when not is_nil(page), do: true
  def page?(_resource), do: false

  @doc "The module implementing this behaviour for a page."
  def adapter(page) when is_atom(page) do
    page
    |> Spark.extensions()
    |> Enum.find_value(fn extension ->
      Code.ensure_loaded?(extension) && function_exported?(extension, :mcp_page_adapter, 0) &&
        extension.mcp_page_adapter()
    end)
    |> case do
      nil ->
        raise ArgumentError,
              "#{inspect(page)} is not a page: none of its extensions exports mcp_page_adapter/0"

      adapter ->
        adapter
    end
  end

  @doc """
  The page session of a caller: a digest of the actor's identity and the page. Callers never
  supply it, so no caller can address another's page rows.
  """
  def session_id(nil, _page), do: nil

  def session_id(actor, page) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({actor_key(actor), page}))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 32)

    "mcp-" <> digest
  end

  # The actor's stable identity: an Ash record's resource and primary key, else its `id`, else
  # the whole term. Fields that vary between a user's requests must not change the session.
  defp actor_key(%resource{} = actor) do
    if Ash.Resource.Info.resource?(resource) do
      {resource, Map.take(actor, Ash.Resource.Info.primary_key(resource))}
    else
      map_actor_key(actor)
    end
  end

  defp actor_key(actor) when is_map(actor), do: map_actor_key(actor)
  defp actor_key(actor), do: actor

  defp map_actor_key(actor) do
    case Map.get(actor, :id, Map.get(actor, "id")) do
      nil -> actor
      id -> {:id, id}
    end
  end

  @doc "The tool name of a page action."
  def tool_name(resource, action) do
    short = resource |> Module.split() |> List.last() |> Macro.underscore()
    String.to_atom("#{short}_#{Macro.underscore(to_string(action))}")
  end

  @doc "The tool name of a page's open tool."
  def open_tool_name(page),
    do: page |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  @doc """
  The tool name of a page's close tool: its open tool's name with `__close`. A page action's tool
  is `<page>_<action>`, so a page's own `close` action keeps `<page>_close`; only an action whose
  snake-cased name is `_close` would clash, and `ensure_unique_names!/1` refuses that.
  """
  def close_tool_name(page), do: String.to_atom("#{open_tool_name(page)}__close")

  @doc """
  The `presentation` argument's JSON schema: an optional string of at most 128 characters, the
  view's live presentation handle. In strict mode (every property required) it is nullable.
  """
  def presentation_schema(strict? \\ false) do
    %{
      "type" => if(strict?, do: ["string", "null"], else: "string"),
      "maxLength" => @presentation_max_length,
      "description" => @presentation_description
    }
  end

  @doc "Adds `presentation` to a generated tool's input schema, beside `input`."
  def put_presentation(%{"properties" => %{} = properties} = schema, strict?) do
    schema
    |> Map.put("properties", Map.put(properties, @presentation, presentation_schema(strict?)))
    |> then(fn schema ->
      if strict?,
        do: Map.update(schema, "required", [@presentation], &(&1 ++ [@presentation])),
        else: schema
    end)
  end

  def put_presentation(schema, _strict?), do: schema

  @doc "The close tool's input schema: `presentation`, required."
  def close_input_schema(strict? \\ false) do
    %{
      "type" => "object",
      "properties" => %{@presentation => presentation_schema(false)},
      "required" => [@presentation]
    }
    |> then(&if(strict?, do: Map.put(&1, "additionalProperties", false), else: &1))
  end

  @doc """
  The generated tools of the page views `ui_resources`: one open tool per page (the page's
  `:mount` create), its close tool, one per bound action. Each is an ordinary `%AshAi.Tool{}`
  (the close tool's is the open tool's, renamed; it runs no action).
  """
  def tools(ui_resources) do
    ui_resources
    |> Enum.filter(&page?/1)
    |> Enum.flat_map(fn resource ->
      adapter = adapter(resource.page)
      meta = %{"ui" => Map.put(@visibility_app, "resourceUri", resource.uri)}

      open = tool(resource.page, :mount, open_tool_name(resource.page), meta, resource)

      close = %{
        open
        | name: close_tool_name(resource.page),
          description: "Closes the #{resource.name} view's live presentation."
      }

      actions =
        resource.page
        |> adapter.actions()
        |> Enum.uniq()
        |> Enum.map(fn {res, action} ->
          tool(res, action, tool_name(res, action), meta, resource)
        end)

      [open, close | actions]
    end)
  end

  defp tool(resource, action_name, name, meta, ui_resource) do
    domain = Ash.Resource.Info.domain(resource)

    action =
      Ash.Resource.Info.action(resource, action_name) ||
        raise ArgumentError,
              "page view `#{ui_resource.name}` binds #{inspect(resource)}.#{action_name}, which does not exist"

    %AshAi.Tool{
      name: name,
      resource: resource,
      action: action,
      domain: domain,
      description:
        action.description ||
          "#{action_name} on #{inspect(resource)}, from the #{ui_resource.name} view.",
      _meta: meta,
      arguments: [],
      load: [],
      forbidden_fields: :hide
    }
  end

  @doc "The page view a tool belongs to (its `_meta.ui.resourceUri` names a page), or nil."
  def view_of(%AshAi.Tool{} = tool, ui_resources) do
    uri = get_in(tool._meta || %{}, ["ui", "resourceUri"])
    uri && Enum.find(ui_resources, &(page?(&1) && &1.uri == uri))
  end

  @doc """
  Prepares a call of a page tool: the session, the context, the view's `presentation` (a
  generated tool's declared argument, taken out of the arguments; nil for the author's tool) and
  the arguments with the session's inputs filled. `{:ok, call}` or `{:error, text}`.
  """
  def prepare(%AshAi.Tool{} = tool, arguments, context, %AshAi.McpUiResource{} = view) do
    case presentation(tool, arguments, view) do
      {:ok, presentation} ->
        prepare(tool, Map.delete(arguments, @presentation), context, view, presentation)

      :none ->
        prepare(tool, arguments, context, view, nil)

      :error ->
        {:error,
         "presentation must be a string of at most #{@presentation_max_length} characters."}
    end
  end

  # A generated tool declares `presentation`; the author's tool does not, and its arguments are
  # left as they are.
  defp presentation(tool, arguments, view) do
    if generated?(tool, view) do
      case Map.get(arguments, @presentation) do
        nil -> {:ok, nil}
        value when is_binary(value) -> valid_presentation(value)
        _other -> :error
      end
    else
      :none
    end
  end

  # Characters as JSON Schema's `maxLength` counts them: code points, not graphemes or bytes.
  defp valid_presentation(value) do
    if String.valid?(value) and length(String.to_charlist(value)) <= @presentation_max_length,
      do: {:ok, value},
      else: :error
  end

  defp prepare(tool, arguments, context, view, presentation) do
    case session_id(context[:actor], view.page) do
      nil ->
        # The author's own tool keeps working for an anonymous caller, without the page; the
        # page's tools need a page session, which needs a signed-in caller.
        if generated?(tool, view),
          do: {:error, "This view needs a signed-in user."},
          else: :anonymous

      session ->
        adapter = adapter(view.page)
        %{context: session_context, inputs: inputs} = adapter.session(view.page, session)

        context = Map.update(context, :context, session_context, &Map.merge(&1, session_context))
        arguments = fill_session_inputs(tool, arguments, inputs, view.page)

        {:ok,
         %{
           session: session,
           adapter: adapter,
           context: context,
           arguments: arguments,
           presentation: presentation
         }}
    end
  end

  # Inputs the session owns are the server's: on the page resource they replace anything the
  # caller sent, both as top-level identity values and as action inputs.
  defp fill_session_inputs(%AshAi.Tool{resource: page} = tool, arguments, inputs, page) do
    inputs = Map.new(inputs, fn {key, value} -> {to_string(key), value} end)
    accepted = accepted_inputs(tool)
    action_inputs = Map.take(inputs, accepted)

    owned = Map.keys(inputs)

    arguments
    |> Map.merge(inputs)
    |> Map.update("input", action_inputs, fn input ->
      (input || %{}) |> Map.drop(owned) |> Map.merge(action_inputs)
    end)
  end

  defp fill_session_inputs(_tool, arguments, _inputs, _page), do: arguments

  @doc """
  Whether a tool is one of a page view's generated tools (its open or close tool, or a bound
  action).
  """
  def generated?(
        %AshAi.Tool{_meta: %{"ui" => %{"visibility" => ["app"], "resourceUri" => uri}}} = tool,
        %AshAi.McpUiResource{uri: uri, page: page}
      ) do
    (tool.resource == page and tool.action.name == :mount) or
      {tool.resource, tool.action.name} in adapter(page).actions(page)
  end

  def generated?(_tool, _view), do: false

  @doc """
  Refuses generated tool names that clash with each other or with the server's other tools: the
  call would otherwise reach whichever one is found first.
  """
  def ensure_unique_names!(tools) do
    case tools
         |> Enum.map(& &1.name)
         |> Enum.frequencies()
         |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] ->
        tools

      clashes ->
        names =
          clashes |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.map_join(", ", &to_string/1)

        raise ArgumentError,
              "page view tools clash with other tools of this server: #{names}; rename the tool or the page action"
    end
  end

  @doc "The input names a tool's action takes."
  def accepted_inputs(%AshAi.Tool{action: action}) do
    Enum.map(Map.get(action, :accept, []) || [], &to_string/1) ++
      Enum.map(action.arguments, &to_string(&1.name))
  end

  @doc """
  The names a page tool's input schema leaves out: the session's inputs, on the page resource.
  """
  def hidden_inputs(%AshAi.Tool{resource: resource}, %AshAi.McpUiResource{page: resource} = view) do
    adapter(view.page).session(view.page, "schema").inputs |> Map.keys() |> Enum.map(&to_string/1)
  end

  def hidden_inputs(_tool, _view), do: []

  @doc """
  Runs a page action's tool through the framework when it runs its own actions (`c:run/4`):
  `{:ok, result}` with the tool result, or `:default` for upstream's execution (any other tool of
  the view, such as the author's linked tool, always runs as upstream).
  """
  def run(%AshAi.Tool{} = tool, call, view, tool_arguments) do
    if function_exported?(call.adapter, :run, 4) and
         {tool.resource, tool.action.name} in call.adapter.actions(view.page) do
      action = %{
        resource: tool.resource,
        action: tool.action.name,
        arguments: call.arguments,
        presentation: call.presentation
      }

      case call.adapter.run(
             view.page,
             call.session,
             action,
             scope(call, view, tool_arguments, [])
           ) do
        :ok ->
          {:ok, %{"isError" => false, "content" => [%{"type" => "text", "text" => "Done."}]}}

        {:error, text} ->
          {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]}}
      end
    else
      :default
    end
  end

  @doc """
  Mounts the caller's page row before an action on the page resource runs, so a page action
  never finds its session missing. Other tools run as they are.
  """
  def ensure_mounted(
        %AshAi.Tool{resource: page, action: %{name: name}},
        call,
        %AshAi.McpUiResource{page: page} = view,
        tool_arguments
      )
      when name != :mount do
    if function_exported?(call.adapter, :mount, 3) do
      call.adapter.mount(view.page, call.session, scope(call, view, tool_arguments, []))
    else
      :ok
    end
  end

  def ensure_mounted(_tool, _call, _view, _tool_arguments), do: :ok

  @doc "Whether a tool is a page view's close tool."
  def close_tool?(
        %AshAi.Tool{resource: page, name: name, _meta: %{"ui" => %{"visibility" => ["app"]}}},
        %AshAi.McpUiResource{page: page}
      ),
      do: name == close_tool_name(page)

  def close_tool?(_tool, _view), do: false

  @doc """
  Answers a call of a view's close tool: the framework's `c:close/3` for the call's
  presentation (required), then "Done."; without the callback, "Done." alone.
  """
  def close(call, view) do
    cond do
      is_nil(call.presentation) ->
        error_result("presentation is required.")

      function_exported?(call.adapter, :close, 3) ->
        case call.adapter.close(view.page, call.session, call.presentation) do
          :ok -> done_result()
          {:error, text} -> error_result(text)
        end

      true ->
        done_result()
    end
  end

  defp done_result,
    do: %{"isError" => false, "content" => [%{"type" => "text", "text" => "Done."}]}

  defp error_result(text),
    do: %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]}

  defp scope(call, view, tool_arguments, errors) do
    %{
      actor: call.context[:actor],
      tenant: call.context[:tenant],
      context: call.context[:context] || %{},
      params: mount_params(tool_arguments),
      errors: errors,
      resource: view,
      presentation: call[:presentation]
    }
  end

  @doc """
  Renders the page after a call and puts it in the result's `_meta`. A render failure leaves the
  result as it is and logs.
  """
  def put_render(result, call, view, tool_arguments, errors, ui_resources) do
    case call.adapter.render(view.page, call.session, scope(call, view, tool_arguments, errors)) do
      {:ok, frame} ->
        frame = Map.update(frame, "bindings", %{}, &tool_bindings(&1, ui_resources))
        meta = Map.put(result["_meta"] || %{}, @meta_key, frame)
        Map.put(result, "_meta", meta)

      {:error, reason} ->
        require Logger
        Logger.warning("AshAi page render failed for #{inspect(view.page)}: #{reason}")
        result
    end
  end

  # `presentation` is the view's handle, not a mount parameter.
  defp mount_params(arguments) do
    arguments
    |> Map.get("input", %{})
    |> case do
      %{} = input -> input
      _other -> %{}
    end
    |> Map.merge(Map.drop(arguments, ["input", @presentation]))
  end

  defp tool_bindings(bindings, _ui_resources) do
    Map.new(bindings, fn {key, binding} ->
      arguments =
        case binding.target do
          {:row, pk} -> Map.new(pk, fn {k, v} -> {to_string(k), v} end)
          _page -> %{}
        end

      {key,
       %{
         "tool" => to_string(tool_name(binding.resource, binding.action)),
         "arguments" => Map.put(arguments, "input", binding.arguments),
         "event" => Map.get(binding, :event, %{}),
         "accept" => binding.accept,
         "boundField" => binding.bound_field
       }}
    end)
  end
end
