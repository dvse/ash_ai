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

  The framework is found through the page resource's Spark extensions: the first extension that
  exports `mcp_page_adapter/0` names the module implementing this behaviour. AshAi depends on no
  UI framework.
  """

  @typedoc """
  What the framework is told when rendering:

    * `:actor`, `:tenant`, `:context` — the request's, with the session's context merged in;
    * `:params` — mount parameters (the linked tool's input fields, by name);
    * `:errors` — error texts of the call that preceded the render;
    * `:resource` — the `%AshAi.McpUiResource{}`.
  """
  @type scope :: %{
          required(:actor) => term(),
          required(:tenant) => term(),
          required(:context) => map(),
          required(:params) => map(),
          required(:errors) => [String.t()],
          required(:resource) => AshAi.McpUiResource.t()
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
  map the template applies, with `"bindings"` as `%{key => binding}`.
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
  shape: `"input"` and top-level identity values). `:ok` or `{:error, text}`.
  """
  @callback run(page :: module(), session_id :: String.t(), call :: map(), scope()) ::
              :ok | {:error, String.t()}

  @optional_callbacks mount: 3, run: 4

  @meta_key "ash_ai/page"
  @visibility_app %{"visibility" => ["app"]}

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

  defp actor_key(%resource{} = actor) do
    if Ash.Resource.Info.resource?(resource) do
      {resource, Map.take(actor, Ash.Resource.Info.primary_key(resource))}
    else
      actor
    end
  end

  defp actor_key(actor), do: actor

  @doc "The tool name of a page action."
  def tool_name(resource, action) do
    short = resource |> Module.split() |> List.last() |> Macro.underscore()
    String.to_atom("#{short}_#{action}")
  end

  @doc "The tool name of a page's open tool."
  def open_tool_name(page),
    do: page |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  @doc """
  The generated tools of the page views `ui_resources`: one open tool per page (the page's
  `:mount` create), one per bound action. Each is an ordinary `%AshAi.Tool{}`.
  """
  def tools(ui_resources) do
    ui_resources
    |> Enum.filter(&page?/1)
    |> Enum.flat_map(fn resource ->
      adapter = adapter(resource.page)
      meta = %{"ui" => Map.put(@visibility_app, "resourceUri", resource.uri)}

      open = tool(resource.page, :mount, open_tool_name(resource.page), meta, resource)

      actions =
        resource.page
        |> adapter.actions()
        |> Enum.uniq()
        |> Enum.map(fn {res, action} ->
          tool(res, action, tool_name(res, action), meta, resource)
        end)

      [open | actions]
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
  Prepares a call of a page tool: the session, the context and the arguments with the session's
  inputs filled. `{:ok, call}` or `{:error, text}`.
  """
  def prepare(%AshAi.Tool{} = tool, arguments, context, %AshAi.McpUiResource{} = view) do
    case session_id(context[:actor], view.page) do
      nil ->
        {:error, "This view needs a signed-in user."}

      session ->
        adapter = adapter(view.page)
        %{context: session_context, inputs: inputs} = adapter.session(view.page, session)

        context = Map.update(context, :context, session_context, &Map.merge(&1, session_context))
        arguments = fill_session_inputs(tool, arguments, inputs, view.page)

        {:ok, %{session: session, adapter: adapter, context: context, arguments: arguments}}
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
  Runs a page tool through the framework when it runs its own actions (`c:run/4`): `{:ok, result}`
  with the tool result, or `:default` for upstream's execution.
  """
  def run(%AshAi.Tool{} = tool, call, view, tool_arguments) do
    if function_exported?(call.adapter, :run, 4) do
      action = %{resource: tool.resource, action: tool.action.name, arguments: call.arguments}

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

  defp scope(call, view, tool_arguments, errors) do
    %{
      actor: call.context[:actor],
      tenant: call.context[:tenant],
      context: call.context[:context] || %{},
      params: mount_params(tool_arguments),
      errors: errors,
      resource: view
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

  defp mount_params(arguments) do
    arguments
    |> Map.get("input", %{})
    |> case do
      %{} = input -> input
      _other -> %{}
    end
    |> Map.merge(Map.drop(arguments, ["input"]))
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
