# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-020 and BLENDED-021 (see BLENDED.md): page-backed MCP Apps views served
# through an `AshAi.McpActions` endpoint, with server and tool icons. The page module stands in
# for a UI framework (ash_blueprint implements `AshAi.McpUiPage` as `AshBlueprint.McpApp`).

defmodule AshAi.Test.McpUiPage.Board do
  @moduledoc false
  @behaviour AshAi.McpUiPage

  @impl true
  def document(opts, context) do
    {:ok,
     ~s(<!doctype html><html><body data-presentation="#{context.presentation_tool}">) <>
       "#{opts[:label]}</body></html>"}
  end

  @impl true
  def present(%{"op" => "echo"} = request, opts, context) do
    {:ok,
     %{
       "request" => request,
       "label" => opts[:label],
       "actor" => context.actor && context.actor.name,
       "tenant" => context.tenant,
       "server_url" => context.server_url,
       "resource" => to_string(context.resource.name)
     }}
  end

  def present(%{"op" => "fail"}, _opts, _context), do: {:error, "the page refused the request"}
  def present(%{"op" => "bad"}, _opts, _context), do: :not_a_result
end

defmodule AshAi.Test.McpUiPage.Broken do
  @moduledoc false
  @behaviour AshAi.McpUiPage

  @impl true
  def document(_opts, _context), do: {:error, :no_document}

  @impl true
  def present(_request, _opts, _context), do: {:error, "unused"}
end

defmodule AshAi.Test.McpUiPage.Note do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.McpUiPage

  actions do
    action :board, :map do
      run fn _input, _context -> {:ok, %{"title" => "Notes board", "count" => 3}} end
    end
  end
end

defmodule AshAi.Test.McpUiPage.Endpoint do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.McpUiPage, extensions: [AshAi.McpActions]

  mcp_actions do
    actions([{AshAi.Test.McpUiPage.Note, :*}])
    mcp_name("notes")
    mcp_server_version("1.0.0")
    mcp_title("Notes")

    mcp_icons([
      %{src: "data:image/svg+xml,%3Csvg%2F%3E", mime_type: "image/svg+xml", sizes: ["any"]},
      %{"src" => "https://notes.example/icon-dark.svg", "theme" => "dark"}
    ])
  end
end

defmodule AshAi.Test.McpUiPage.PlainEndpoint do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.McpUiPage, extensions: [AshAi.McpActions]

  mcp_actions do
    actions([{AshAi.Test.McpUiPage.Note, :*}])
    mcp_resources([:html_app])
  end
end

defmodule AshAi.Test.McpUiPage do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi]

  alias AshAi.Test.McpUiPage.Note

  tools do
    tool :show_board, Note, :board,
      ui: :board,
      icons: [%{src: "https://notes.example/board.svg", mime_type: "image/svg+xml"}],
      _meta: %{"openai/ui" => %{"entrypoints" => [%{"type" => "global"}]}}

    tool :show_app, Note, :board, ui: :html_app
    tool :plain_board, Note, :board
  end

  mcp_resources do
    mcp_ui_resource :board, "ui://notes/board",
      page: {AshAi.Test.McpUiPage.Board, label: "Board view"},
      title: "Board",
      prefers_border: true,
      domain: "notes.example",
      _meta: %{"openai/ui" => %{"availableDisplayModes" => ["inline", "fullscreen"]}}

    mcp_ui_resource :html_app, "ui://notes/app.html",
      html_path: "test/fixtures/test_app.html",
      domain: nil

    mcp_ui_resource :broken, "ui://notes/broken",
      page: AshAi.Test.McpUiPage.Broken,
      domain: nil
  end

  resources do
    resource Note
    resource AshAi.Test.McpUiPage.Endpoint
    resource AshAi.Test.McpUiPage.PlainEndpoint
  end
end
