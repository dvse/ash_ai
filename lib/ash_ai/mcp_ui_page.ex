# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpUiPage do
  @moduledoc """
  A page-backed MCP Apps view (BLENDED-020).

  An `mcp_ui_resource` with `page: {Module, opts}` serves a page of the application's own UI
  framework as its MCP Apps document, instead of a hand-written file at `html_path`. AshAi does
  not know the framework: `Module` implements this behaviour. (`AshBlueprint.McpApp` implements
  it for ash_blueprint pages.)

  The framework supplies two things:

    * `c:document/2` — the view: one self-contained HTML document, served by `resources/read` as
      `text/html;profile=mcp-app`. It speaks the MCP Apps bridge (`ui/initialize`, tool-input and
      tool-result notifications, `tools/call`, display modes) and renders the page.
    * `c:present/3` — the page's server side, reached through one app-only tool (the
      *presentation tool*). The document calls it with `tools/call` over the bridge to open the
      page, dispatch its events and re-render. The request and its result are the framework's
      own (opaque to AshAi); they run under the caller's actor, tenant and context, so the page's
      actions are authorized as any other call is.

  The resource's URI gains the document's content digest, `<uri>@<digest8>` (the first eight hex
  digits of its SHA-256), because MCP hosts cache a view by its URI (ChatGPT for up to an hour).
  A tool linked to the resource (`ui:`) carries the digest URI in `_meta.ui.resourceUri` and its
  OpenAI alias `_meta["openai/outputTemplate"]`.

  The presentation tool is named `<resource name>_presentation`. It is listed with
  `_meta.ui.visibility: ["app"]`, so hosts never offer it to the model.
  """

  @typedoc """
  What the framework is told about the request:

    * `:resource` — the `%AshAi.McpUiResource{}`;
    * `:presentation_tool` — the name of the app-only tool the document calls;
    * `:actor`, `:tenant`, `:context` — the MCP request's;
    * `:server_url` — the MCP endpoint's public URL, when known.
  """
  @type context :: %{
          required(:resource) => AshAi.McpUiResource.t(),
          required(:presentation_tool) => String.t(),
          optional(:actor) => term(),
          optional(:tenant) => term(),
          optional(:context) => map(),
          optional(:server_url) => String.t() | nil
        }

  @doc "The view's HTML document. It must not depend on the caller: its digest is the URI's."
  @callback document(opts :: keyword(), context()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Answers one presentation request from the document (the `request` argument of the
  presentation tool). `{:ok, map}` becomes the tool result's `structuredContent`; `{:error,
  text}` an `isError` result.
  """
  @callback present(request :: map(), opts :: keyword(), context()) ::
              {:ok, map()} | {:error, String.t()}

  @presentation_suffix "_presentation"

  @doc "The app-only presentation tool's name for a page-backed resource."
  def presentation_tool(%AshAi.McpUiResource{name: name}), do: "#{name}#{@presentation_suffix}"

  @doc "Whether a UI resource is page-backed."
  def page?(%AshAi.McpUiResource{page: {_module, _opts}}), do: true
  def page?(_resource), do: false

  @doc """
  The page's document, rendered with the request's context. Returns `{:ok, html}` or
  `{:error, reason}`; a non-string document is an error naming the module.
  """
  def document(%AshAi.McpUiResource{page: {module, opts}} = resource, server_opts) do
    case module.document(opts, context(resource, server_opts)) do
      {:ok, html} when is_binary(html) ->
        {:ok, html}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error,
         "#{inspect(module)}.document/2 must return {:ok, html} or {:error, reason}, got: " <>
           inspect(other)}
    end
  end

  @doc "The resource's URI: the declared URI, with `@<digest8>` when page-backed."
  def uri(%AshAi.McpUiResource{} = resource, server_opts) do
    if page?(resource) do
      case document(resource, server_opts) do
        {:ok, html} -> "#{resource.uri}@#{digest8(html)}"
        {:error, _reason} -> resource.uri
      end
    else
      resource.uri
    end
  end

  @doc "The first eight hex digits of the SHA-256 of a text."
  def digest8(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc """
  The `tools/list` entry of a page-backed resource's presentation tool. Its input is one
  `request` object whose shape belongs to the framework.
  """
  def presentation_tool_definition(%AshAi.McpUiResource{} = resource) do
    title = resource.title || to_string(resource.name)

    %{
      "name" => presentation_tool(resource),
      "title" => "#{title} (view)",
      "description" =>
        "Serves the #{title} view: opens its page, dispatches its events and renders it. " <>
          "Called by the view only.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "request" => %{
            "type" => "object",
            "description" => "A presentation request from the view."
          }
        },
        "required" => ["request"]
      },
      # BLENDED-009 defaults for a generic action that may write.
      "annotations" => %{
        "readOnlyHint" => false,
        "destructiveHint" => true,
        "idempotentHint" => false,
        "openWorldHint" => false
      },
      "_meta" => %{"ui" => %{"visibility" => ["app"]}}
    }
  end

  @doc """
  Runs a presentation tool call. Returns `{:ok, mcp_result}`: `structuredContent` (and its JSON
  text) on success, an `isError` text otherwise.
  """
  def present(%AshAi.McpUiResource{page: {module, opts}} = resource, arguments, server_opts) do
    case arguments do
      %{"request" => request} when is_map(request) ->
        case module.present(request, opts, context(resource, server_opts)) do
          {:ok, result} when is_map(result) ->
            {:ok,
             %{
               "isError" => false,
               "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
               "structuredContent" => result
             }}

          {:error, text} when is_binary(text) ->
            {:ok, error_result(text)}

          other ->
            raise ArgumentError,
                  "#{inspect(module)}.present/3 must return {:ok, map} or {:error, text}, got: " <>
                    inspect(other)
        end

      _ ->
        {:ok, error_result("request must be an object")}
    end
  end

  defp error_result(text),
    do: %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]}

  defp context(resource, server_opts) do
    %{
      resource: resource,
      presentation_tool: presentation_tool(resource),
      actor: server_opts[:actor],
      tenant: server_opts[:tenant],
      context: server_opts[:context] || %{},
      server_url: server_opts[:server_url]
    }
  end
end
