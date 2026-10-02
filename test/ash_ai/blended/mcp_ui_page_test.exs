# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpUiPageTest do
  @moduledoc """
  BLENDED-020 (page-backed MCP Apps views: `mcp_ui_resource ... page:`, the digest URI, the
  OpenAI alias, the app-only presentation tool, resource `_meta`) and BLENDED-021 (server
  `title` and `icons`, tool `icons`) over MCP.
  """
  use ExUnit.Case, async: false

  alias AshAi.Test.McpUiPage.{Endpoint, PlainEndpoint}

  @ui_mime_type "text/html;profile=mcp-app"
  @document ~s(<!doctype html><html><body data-presentation="board_presentation">Board view</body></html>)
  @digest :sha256 |> :crypto.hash(@document) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  @board_uri "ui://notes/board@#{@digest}"
  @alice %{name: "alice"}

  describe "BLENDED-020 digest URI" do
    test "a page-backed resource is listed at its declared URI plus the document's digest" do
      resources = resources()
      board = Enum.find(resources, &(&1["name"] == "board"))
      assert board["uri"] == @board_uri
      assert board["mimeType"] == @ui_mime_type
      assert board["title"] == "Board"
    end

    test "a static resource keeps its declared URI" do
      assert Enum.find(resources(), &(&1["name"] == "html_app"))["uri"] == "ui://notes/app.html"
    end

    test "a page whose document fails keeps its declared URI and cannot be read" do
      assert Enum.find(resources(), &(&1["name"] == "broken"))["uri"] == "ui://notes/broken"

      assert %{"error" => %{"code" => -32_603, "data" => %{"error" => error}}} =
               rpc("resources/read", %{"uri" => "ui://notes/broken"})

      assert error =~ "Failed to render page: :no_document"
    end

    test "resources/read serves the page's document at the digest URI only" do
      assert %{"result" => %{"contents" => [content]}} =
               rpc("resources/read", %{"uri" => @board_uri})

      assert content["uri"] == @board_uri
      assert content["mimeType"] == @ui_mime_type
      assert content["text"] == @document

      assert %{"error" => %{"code" => -32_002}} =
               rpc("resources/read", %{"uri" => "ui://notes/board"})

      assert %{"error" => %{"code" => -32_002}} =
               rpc("resources/read", %{"uri" => "ui://notes/board@00000000"})
    end

    test "the resource's _meta keys sit beside ui, in the list and the read alike" do
      listed = Enum.find(resources(), &(&1["name"] == "board"))["_meta"]

      assert listed == %{
               "ui" => %{"csp" => %{}, "domain" => "notes.example", "prefersBorder" => true},
               "openai/ui" => %{"availableDisplayModes" => ["inline", "fullscreen"]}
             }

      %{"result" => %{"contents" => [content]}} = rpc("resources/read", %{"uri" => @board_uri})
      assert content["_meta"] == listed
    end

    test "a document that is neither {:ok, html} nor {:error, reason} is an error naming the module" do
      defmodule NotADocument do
        @moduledoc false
        def document(_opts, _context), do: :nope
        def present(_request, _opts, _context), do: {:error, "unused"}
      end

      resource = %AshAi.McpUiResource{name: :x, uri: "ui://x/x", page: {NotADocument, []}}
      assert {:error, message} = AshAi.McpUiPage.document(resource, [])
      assert message =~ "NotADocument.document/2 must return {:ok, html}"
      assert AshAi.McpUiPage.uri(resource, []) == "ui://x/x"
    end

    test "the digest follows the document" do
      resource = %AshAi.McpUiResource{
        name: :board,
        uri: "ui://notes/board",
        page: {AshAi.Test.McpUiPage.Board, label: "Other"}
      }

      assert AshAi.McpUiPage.uri(resource, []) =~ ~r"^ui://notes/board@[0-9a-f]{8}$"
      refute AshAi.McpUiPage.uri(resource, []) == @board_uri
    end
  end

  describe "BLENDED-020 tools" do
    test "a tool linked to a page names its digest URI under ui.resourceUri and the OpenAI alias" do
      tool = tool("show_board")
      assert tool["_meta"]["ui"]["resourceUri"] == @board_uri
      assert tool["_meta"]["openai/outputTemplate"] == @board_uri
      assert tool["_meta"]["openai/ui"] == %{"entrypoints" => [%{"type" => "global"}]}
    end

    test "a tool linked to a static resource keeps upstream's _meta" do
      assert tool("show_app")["_meta"] == %{"ui" => %{"resourceUri" => "ui://notes/app.html"}}
      refute Map.has_key?(tool("plain_board"), "_meta")
    end

    test "each page-backed resource adds one app-only presentation tool" do
      presentation = tool("board_presentation")
      assert presentation["_meta"] == %{"ui" => %{"visibility" => ["app"]}}
      assert presentation["title"] == "Board (view)"
      assert presentation["inputSchema"]["required"] == ["request"]
      assert presentation["annotations"]["readOnlyHint"] == false
      assert tool("broken_presentation")
      refute tool("html_app_presentation")
    end

    test "presentation tools follow the served resources" do
      names = tool_names(PlainEndpoint)
      refute "board_presentation" in names
      assert "show_board" in names
    end

    test "the presentation tool answers with the page's result, as the caller" do
      result = call("board_presentation", %{"request" => %{"op" => "echo", "n" => 1}})
      refute result["isError"]

      assert result["structuredContent"] == %{
               "request" => %{"op" => "echo", "n" => 1},
               "label" => "Board view",
               "actor" => "alice",
               "tenant" => nil,
               "server_url" => "https://notes.example/mcp",
               "resource" => "board"
             }

      assert Jason.decode!(hd(result["content"])["text"]) == result["structuredContent"]
    end

    test "a page's refusal and a malformed request are tool errors" do
      assert %{"isError" => true, "content" => [%{"text" => "the page refused the request"}]} =
               call("board_presentation", %{"request" => %{"op" => "fail"}})

      assert %{"isError" => true, "content" => [%{"text" => "request must be an object"}]} =
               call("board_presentation", %{"request" => "open"})
    end

    test "a page result that is neither {:ok, map} nor {:error, text} raises" do
      # The MCP action wraps the raise, as it wraps any raise inside the server.
      assert_raise Ash.Error.Unknown, ~r/present\/3 must return/, fn ->
        call("board_presentation", %{"request" => %{"op" => "bad"}})
      end
    end
  end

  describe "BLENDED-020 DSL" do
    test "a UI resource needs exactly one of html_path and page" do
      assert_raise Spark.Error.DslError, ~r/needs `html_path`.*or `page`/s, fn ->
        domain(
          quote do
            mcp_resources do
              mcp_ui_resource(:none, "ui://x/none")
            end
          end
        )
      end

      assert_raise Spark.Error.DslError, ~r/sets both `html_path` and `page`/, fn ->
        domain(
          quote do
            mcp_resources do
              mcp_ui_resource(:both, "ui://x/both",
                html_path: "x.html",
                page: AshAi.Test.McpUiPage.Board
              )
            end
          end
        )
      end
    end

    test "a presentation tool may not shadow a declared tool" do
      assert_raise Spark.Error.DslError, ~r/app-only tool `board_presentation`/, fn ->
        domain(
          quote do
            tools do
              tool(:board_presentation, AshAi.Test.McpUiPage.Note, :board)
            end

            mcp_resources do
              mcp_ui_resource(:board, "ui://x/board", page: AshAi.Test.McpUiPage.Board)
            end
          end
        )
      end
    end

    test "page takes a module or {module, opts}" do
      domain =
        domain(
          quote do
            mcp_resources do
              mcp_ui_resource(:a, "ui://x/a", page: AshAi.Test.McpUiPage.Board)
              mcp_ui_resource(:b, "ui://x/b", page: {AshAi.Test.McpUiPage.Board, label: "B"})
            end
          end
        )

      assert [%{page: {AshAi.Test.McpUiPage.Board, []}}, %{page: {_, [label: "B"]}}] =
               AshAi.Info.mcp_ui_resources(domain)
    end
  end

  describe "BLENDED-021 icons and title" do
    test "serverInfo carries the configured title and icons" do
      %{"result" => %{"serverInfo" => info}} =
        rpc("initialize", %{"protocolVersion" => "2025-06-18"})

      assert info == %{
               "name" => "notes",
               "version" => "1.0.0",
               "title" => "Notes",
               "icons" => [
                 %{
                   "src" => "data:image/svg+xml,%3Csvg%2F%3E",
                   "mimeType" => "image/svg+xml",
                   "sizes" => ["any"]
                 },
                 %{"src" => "https://notes.example/icon-dark.svg", "theme" => "dark"}
               ]
             }
    end

    test "2026-07-28 results carry the same serverInfo" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }

      headers = %{"mcp-protocol-version" => "2026-07-28", "mcp-method" => "tools/list"}

      %{"result" => %{"_meta" => meta}} = rpc_raw(%{"body" => body, "headers" => headers})
      info = meta["io.modelcontextprotocol/serverInfo"]
      assert info["title"] == "Notes"
      assert length(info["icons"]) == 2
    end

    test "without them serverInfo is upstream's" do
      %{"result" => %{"serverInfo" => info}} =
        rpc("initialize", %{"protocolVersion" => "2025-06-18"}, PlainEndpoint)

      assert Map.keys(info) |> Enum.sort() == ["name", "version"]
    end

    test "a tool's icons are emitted on the tool" do
      assert tool("show_board")["icons"] == [
               %{"src" => "https://notes.example/board.svg", "mimeType" => "image/svg+xml"}
             ]

      refute Map.has_key?(tool("plain_board"), "icons")
    end

    test "an icon that is not an MCP Icon is refused" do
      for {icon, message} <- [
            {%{src: "javascript:alert(1)"}, ~r/src must be/},
            {%{src: "https://x/i.svg", size: "1"}, ~r/unknown keys size/},
            {%{src: "https://x/i.svg", theme: "blue"}, ~r/theme must be/},
            {%{src: "https://x/i.svg", sizes: "any"}, ~r/sizes must be a list/},
            {%{src: "https://x/i.svg", mime_type: 1}, ~r/mime_type must be/},
            {"https://x/i.svg", ~r/an icon must be a map/}
          ] do
        assert_raise ArgumentError, message, fn -> AshAi.Mcp.Icons.normalize([icon], "tool t") end
      end

      assert_raise ArgumentError, ~r/must be a list of maps/, fn ->
        AshAi.Mcp.Icons.normalize(%{}, "tool t")
      end

      assert AshAi.Mcp.Icons.normalize([], "tool t") == nil
    end
  end

  defp domain(body) do
    name = Module.concat(__MODULE__, "Domain#{System.unique_integer([:positive])}")

    Code.eval_quoted(
      quote do
        defmodule unquote(name) do
          use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi], validate_config_inclusion?: false

          unquote(body)

          resources do
            allow_unregistered? true
          end
        end
      end
    )

    name
  end

  defp resources, do: rpc("resources/list", %{})["result"]["resources"]

  defp tool_names(endpoint \\ Endpoint) do
    %{"result" => %{"tools" => tools}} = rpc("tools/list", %{}, endpoint)
    Enum.map(tools, & &1["name"])
  end

  defp tool(name) do
    %{"result" => %{"tools" => tools}} = rpc("tools/list", %{})
    Enum.find(tools, &(&1["name"] == name))
  end

  defp call(name, arguments) do
    %{"result" => result} = rpc("tools/call", %{"name" => name, "arguments" => arguments})
    result
  end

  defp rpc(method, params, endpoint \\ Endpoint) do
    rpc_raw(
      %{
        "body" => %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        "headers" => %{}
      },
      endpoint
    )
  end

  defp rpc_raw(request, endpoint \\ Endpoint) do
    request = Map.put(request, "server_url", "https://notes.example/mcp")

    {:ok, %{status: 200, body: body}} =
      endpoint
      |> Ash.ActionInput.for_action(:mcp, %{request: request}, actor: @alice)
      |> Ash.run_action()

    Jason.decode!(body)
  end
end
