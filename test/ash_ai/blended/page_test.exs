# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.PageTest do
  @moduledoc """
  BLENDED-020: `mcp_ui_resource ... page:` — a page as an MCP Apps view. The template is the
  page's client, the page's bound actions are app-only tools, every result of a tool of the view
  carries the page rendered for the caller, and the page session is the caller's.
  """
  use ExUnit.Case, async: false

  alias AshAi.Test.Page.{CounterPage, GuardedPage, Item}

  @alice %{id: "alice", name: "Alice"}
  @bob %{id: "bob", name: "Bob"}

  setup do
    for resource <- [CounterPage, Item, GuardedPage],
        record <- Ash.read!(resource),
        do: Ash.destroy!(record)

    :ok
  end

  describe "declaration" do
    test "a view takes html_path or page: neither is refused" do
      assert_raise Spark.Error.DslError, ~r/needs `html_path` or `page`/, fn ->
        defmodule Neither do
          use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

          resources do
            resource Item
          end

          mcp_resources do
            mcp_ui_resource :v, "ui://v"
          end
        end
      end
    end

    test "a view takes html_path or page: both is refused" do
      assert_raise Spark.Error.DslError, ~r/not both/, fn ->
        defmodule Both do
          use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

          resources do
            resource Item
          end

          mcp_resources do
            mcp_ui_resource :v, "ui://v", html_path: "x.html", page: CounterPage
          end
        end
      end
    end
  end

  describe "listing and the template" do
    test "the view is listed at its authored URI and read as the page's client" do
      %{"result" => %{"resources" => resources}} = rpc("resources/list", %{}, @alice)
      view = Enum.find(resources, &(&1["uri"] == "ui://counter/view"))
      assert view["mimeType"] == "text/html;profile=mcp-app"
      assert view["title"] == "Counter"

      %{"result" => %{"contents" => [content]}} =
        rpc("resources/read", %{"uri" => "ui://counter/view"}, @alice)

      assert content["mimeType"] == "text/html;profile=mcp-app"
      assert content["text"] =~ ~s(data-page="AshAi.Test.Page.CounterPage")
      assert content["text"] =~ "<title>Counter</title>"
    end

    test "a page view declares upstream's empty csp: its template loads nothing" do
      %{"result" => %{"resources" => resources}} = rpc("resources/list", %{}, @alice)
      view = Enum.find(resources, &(&1["uri"] == "ui://counter/view"))
      assert view["_meta"]["ui"]["csp"] == %{}
      static = Enum.find(resources, &(&1["uri"] == "ui://static/view.html"))
      assert static["_meta"]["ui"]["csp"] == %{}
    end

    test "the template is the same for every caller" do
      read = fn actor ->
        %{"result" => %{"contents" => [c]}} =
          rpc("resources/read", %{"uri" => "ui://counter/view"}, actor)

        c["text"]
      end

      assert read.(@alice) == read.(@bob)
    end

    test "an html_path view is served as upstream" do
      %{"result" => %{"contents" => [c]}} =
        rpc("resources/read", %{"uri" => "ui://static/view.html"}, @alice)

      assert c["text"] =~ "BLENDED-020"
    end

    test "the page's open tool and bound actions are app-only tools of the view" do
      tools = tools(@alice)

      for name <- ["counter_page", "counter_page__close", "counter_page_increment", "item_toggle"] do
        tool = Map.fetch!(tools, name)

        assert tool["_meta"]["ui"] == %{
                 "resourceUri" => "ui://counter/view",
                 "visibility" => ["app"]
               }
      end

      assert tools["show_counter"]["_meta"]["ui"] == %{"resourceUri" => "ui://counter/view"}
    end

    test "the page tools follow the served views, not the tools option" do
      assert Map.has_key?(tools(@alice, tools: [:list_items]), "counter_page_increment")
      refute Map.has_key?(tools(@alice, mcp_resources: [:static]), "counter_page_increment")
    end

    test "every generated tool declares the view's presentation beside input; others do not" do
      tools = tools(@alice)
      presentation = AshAi.Page.presentation_schema()

      assert presentation == %{
               "type" => "string",
               "maxLength" => 128,
               "description" => "The view's live presentation, as the page last returned it."
             }

      for name <- ["counter_page", "counter_page_increment", "item_toggle", "guarded_page_bump"] do
        schema = tools[name]["inputSchema"]
        assert schema["properties"]["presentation"] == presentation
        refute "presentation" in (schema["required"] || [])
      end

      increment = tools["counter_page_increment"]["inputSchema"]["properties"]
      assert Map.keys(increment) == ["input", "presentation"]
      refute Map.has_key?(increment["input"]["properties"], "presentation")

      for name <- ["show_counter", "list_items"] do
        refute Map.has_key?(tools[name]["inputSchema"]["properties"], "presentation")
      end
    end

    test "the close tool is app-only and takes the presentation alone" do
      tools = tools(@alice)
      close = tools["counter_page__close"]

      assert close["_meta"]["ui"] == %{
               "resourceUri" => "ui://counter/view",
               "visibility" => ["app"]
             }

      assert close["inputSchema"] == %{
               "type" => "object",
               "properties" => %{"presentation" => AshAi.Page.presentation_schema()},
               "required" => ["presentation"]
             }

      refute Map.has_key?(close, "outputSchema")
      assert close["description"] == "Closes the counter view's live presentation."
      assert tools["guarded_page__close"]["_meta"]["ui"]["resourceUri"] == "ui://guarded/view"
      refute Map.has_key?(tools(@alice, mcp_resources: [:static]), "counter_page__close")
    end

    test "a server without page views lists exactly the tools it listed before them" do
      golden =
        "test/ash_ai/blended/tools_list_without_pages.json" |> File.read!() |> Jason.decode!()

      blended =
        raw_tools_list(
          otp_app: :ash_ai,
          actions: [
            {AshAi.Test.Blended.Post, :*},
            {AshAi.Test.Blended.Author, :*},
            {AshAi.Test.Blended.Comment, :*}
          ],
          actor: %{admin: true}
        )

      assert blended == golden["blended"]

      static =
        raw_tools_list(
          otp_app: :ash_ai,
          actions: [{Item, :*}],
          tools: [:list_items],
          mcp_resources: [:static],
          actor: %{id: "alice"}
        )

      assert static == golden["static_view_only"]
    end

    test "the session's inputs are not in a page tool's input schema" do
      schema = tools(@alice)["counter_page_increment"]["inputSchema"]
      refute Map.has_key?(schema["properties"], "session_id")
      assert schema["properties"]["input"]["properties"]["by"]
      refute Map.has_key?(schema["properties"]["input"]["properties"], "session_id")
    end
  end

  describe "calls" do
    test "the linked tool's result carries the page rendered for the caller" do
      Ash.create!(Item, %{label: "one"})
      result = call("show_counter", %{}, @alice)

      refute result["isError"]
      assert is_list(result["structuredContent"]["result"]) or is_map(result["structuredContent"])
      page = result["_meta"]["ash_ai/page"]
      assert page["html"] =~ "count=0"
      assert page["html"] =~ "session=" <> AshAi.Page.session_id(@alice, CounterPage)

      assert page["bindings"]["increment"] == %{
               "tool" => "counter_page_increment",
               "arguments" => %{"input" => %{"by" => 1}},
               "event" => %{},
               "accept" => ["by"],
               "boundField" => nil
             }

      [{_key, toggle}] =
        Enum.filter(page["bindings"], fn {k, _} -> String.starts_with?(k, "toggle-") end)

      assert toggle["tool"] == "item_toggle"
      assert Map.has_key?(toggle["arguments"], "id")
    end

    test "a page action runs on the caller's page row, as the caller, and re-renders" do
      call("counter_page", %{}, @alice)
      result = call("counter_page_increment", %{"input" => %{"by" => 2}}, @alice)

      refute result["isError"]
      assert result["structuredContent"]["count"] == 2
      assert result["_meta"]["ash_ai/page"]["html"] =~ "count=2 by=Alice"
    end

    test "callers cannot address another caller's page session" do
      call("counter_page_increment", %{"input" => %{"by" => 5}}, @alice)
      alice_session = AshAi.Page.session_id(@alice, CounterPage)

      result =
        call(
          "counter_page_increment",
          %{
            "session_id" => alice_session,
            "input" => %{"by" => 1, "session_id" => alice_session}
          },
          @bob
        )

      assert result["_meta"]["ash_ai/page"]["html"] =~ "count=1 by=Bob"
      assert call("counter_page", %{}, @alice)["_meta"]["ash_ai/page"]["html"] =~ "count=5"
    end

    test "a row binding's tool acts on the row" do
      item = Ash.create!(Item, %{label: "one"})
      result = call("item_toggle", %{"id" => item.id}, @alice)
      refute result["isError"]
      assert Ash.get!(Item, item.id).done?
      assert result["_meta"]["ash_ai/page"]
    end

    test "a refused action is an error result whose page shows the error" do
      result = call("counter_page_increment", %{"input" => %{"by" => -1}}, @alice)
      assert result["isError"]
      [error] = result["_meta"]["ash_ai/page"]["errors"]
      assert error =~ "must not be negative"
    end

    test "a call without an actor is refused" do
      result = call("counter_page", %{}, nil)
      assert result["isError"]
      assert [%{"text" => "This view needs a signed-in user."}] = result["content"]
      refute result["_meta"]
    end

    test "a framework that runs its own actions answers its page's tools" do
      result = call("guarded_page_bump", %{"input" => %{"count" => 3}}, @alice)
      refute result["isError"]
      assert result["content"] == [%{"type" => "text", "text" => "Done."}]
      assert result["_meta"]["ash_ai/page"]["html"] == "count=3"

      refused = call("guarded_page_bump", %{"input" => %{"count" => -1}}, @alice)
      assert refused["isError"]
      assert refused["_meta"]["ash_ai/page"]["errors"] == ["the page refused the bump"]
      assert refused["_meta"]["ash_ai/page"]["html"] == "count=3"

      Ash.create!(Item, %{label: "one"})
      linked = call("show_guarded", %{}, @alice)
      refute linked["isError"]
      assert [%{"text" => text}] = linked["content"]
      assert text =~ ~s("label":"one")
      assert linked["_meta"]["ash_ai/page"]["html"] == "count=3"
    end

    test "the author's linked tool still answers an anonymous caller, without the page" do
      result = call("show_counter", %{}, nil)
      refute result["isError"]
      refute result["_meta"]["ash_ai/page"]
    end

    test "a user's page session follows their identity, not the rest of the actor" do
      assert AshAi.Page.session_id(%{id: "alice", name: "Alice"}, CounterPage) ==
               AshAi.Page.session_id(%{id: "alice", name: "A.", lease: 2}, CounterPage)

      refute AshAi.Page.session_id(@alice, CounterPage) ==
               AshAi.Page.session_id(@bob, CounterPage)

      refute AshAi.Page.session_id(@alice, CounterPage) == AshAi.Page.session_id(@alice, Item)
    end

    test "page view tools may not clash with other tools" do
      tools = [%AshAi.Tool{name: :counter_page}, %AshAi.Tool{name: :counter_page}]

      assert_raise ArgumentError, ~r/clash with other tools of this server: counter_page/, fn ->
        AshAi.Page.ensure_unique_names!(tools)
      end
    end

    test "the view's presentation reaches the framework, never the action" do
      call("counter_page", %{"presentation" => "tab-1"}, @alice)
      assert_received {:page_render, "tab-1"}

      result =
        call(
          "counter_page_increment",
          %{"presentation" => "tab-1", "input" => %{"by" => 2}},
          @alice
        )

      refute result["isError"]
      assert_received {:page_mount, "tab-1"}
      assert_received {:increment_params, params}
      refute Map.has_key?(params, "presentation")
      refute Map.has_key?(params, :presentation)
      assert_received {:page_render, "tab-1"}
      assert result["_meta"]["ash_ai/page"]["presentation"] == "next:tab-1"
      refute Map.has_key?(result["_meta"]["ash_ai/page"]["params"], "presentation")

      bumped =
        call(
          "guarded_page_bump",
          %{"presentation" => "tab-2", "input" => %{"count" => 1}},
          @alice
        )

      refute bumped["isError"]
      assert_received {:page_run, "tab-2", "tab-2", arguments}
      refute Map.has_key?(arguments, "presentation")
    end

    test "without a presentation the framework is told nil, and the render answers one" do
      result = call("counter_page", %{}, @alice)
      assert_received {:page_render, nil}
      assert result["_meta"]["ash_ai/page"]["presentation"] == "fresh"

      call("show_counter", %{"presentation" => "ignored"}, @alice)
      assert_received {:page_render, nil}
    end

    test "a presentation that is not a string of at most 128 characters is refused" do
      for value <- [String.duplicate("x", 129), 7, %{"a" => 1}] do
        result = call("counter_page_increment", %{"presentation" => value}, @alice)
        assert result["isError"]

        assert result["content"] == [
                 %{
                   "type" => "text",
                   "text" => "presentation must be a string of at most 128 characters."
                 }
               ]

        refute result["_meta"]
      end

      refute call("counter_page", %{"presentation" => String.duplicate("é", 128)}, @alice)[
               "isError"
             ]

      # Code points, as JSON Schema counts maxLength: 65 "e" + combining acute are 65 graphemes
      # but 130 characters; 128 astral characters are 128.
      assert call("counter_page", %{"presentation" => String.duplicate("e\u0301", 65)}, @alice)[
               "isError"
             ]

      refute call("counter_page", %{"presentation" => String.duplicate("😀", 128)}, @alice)[
               "isError"
             ]
    end

    test "the close tool closes the caller's presentation through the framework" do
      session = AshAi.Page.session_id(@alice, CounterPage)
      result = call("counter_page__close", %{"presentation" => "tab-1"}, @alice)

      assert result == %{
               "isError" => false,
               "content" => [%{"type" => "text", "text" => "Done."}]
             }

      assert_received {:page_close, ^session, "tab-1"}
      refute_received {:page_render, _}

      refused = call("counter_page__close", %{"presentation" => "stuck"}, @alice)
      assert refused["isError"]

      assert refused["content"] == [
               %{"type" => "text", "text" => "the presentation would not close"}
             ]

      assert_received {:page_close, ^session, "stuck"}

      missing = call("counter_page__close", %{}, @alice)
      assert missing["content"] == [%{"type" => "text", "text" => "presentation is required."}]
      refute_received {:page_close, _, _}

      assert call("counter_page__close", %{"presentation" => "tab-1"}, nil)["content"] == [
               %{"type" => "text", "text" => "This view needs a signed-in user."}
             ]
    end

    test "a framework without close/3 answers the close tool, doing nothing" do
      assert call("guarded_page__close", %{"presentation" => "tab-1"}, @alice) ==
               %{"isError" => false, "content" => [%{"type" => "text", "text" => "Done."}]}
    end

    test "a page action named close keeps its own tool, apart from the close tool" do
      tools = tools(@alice)
      assert tools["counter_page_close"]["inputSchema"]["properties"]["presentation"]

      assert tools["counter_page__close"]["description"] ==
               "Closes the counter view's live presentation."

      call("counter_page_increment", %{"input" => %{"by" => 3}}, @alice)
      result = call("counter_page_close", %{"presentation" => "tab-1"}, @alice)
      refute result["isError"]
      assert result["structuredContent"]["count"] == 0
      assert_received {:page_render, "tab-1"}
      refute_received {:page_close, _, _}

      closed = call("counter_page__close", %{"presentation" => "tab-1"}, @alice)
      assert closed["content"] == [%{"type" => "text", "text" => "Done."}]
      assert_received {:page_close, _, "tab-1"}

      assert_raise ArgumentError,
                   ~r/clash with other tools of this server: counter_page__close/,
                   fn ->
                     AshAi.Page.ensure_unique_names!([
                       %AshAi.Tool{name: AshAi.Page.tool_name(CounterPage, :_close)},
                       %AshAi.Tool{name: AshAi.Page.close_tool_name(CounterPage)}
                     ])
                   end
    end

    test "a close tool name clashes like any page tool" do
      tools = [%AshAi.Tool{name: :counter_page__close}, %AshAi.Tool{name: :counter_page__close}]

      assert_raise ArgumentError,
                   ~r/clash with other tools of this server: counter_page__close/,
                   fn -> AshAi.Page.ensure_unique_names!(tools) end
    end

    test "tools that are not the view's carry no page" do
      result = call("list_items", %{}, @alice)
      refute result["_meta"]["ash_ai/page"]
    end
  end

  defp raw_tools_list(opts) do
    Plug.Test.conn(:post, "/", %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => "list"})
    |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
    |> AshAi.Mcp.Router.call(AshAi.Mcp.Router.init(opts))
    |> Map.fetch!(:resp_body)
  end

  defp tools(actor, opts \\ []) do
    %{"result" => %{"tools" => tools}} = rpc("tools/list", %{}, actor, opts)
    Map.new(tools, &{&1["name"], &1})
  end

  defp call(name, arguments, actor) do
    %{"result" => result} = rpc("tools/call", %{"name" => name, "arguments" => arguments}, actor)
    result
  end

  defp rpc(method, params, actor, opts \\ []) do
    router_opts =
      AshAi.Mcp.Router.init(
        Keyword.merge(
          [
            otp_app: :ash_ai,
            actions: [{Item, :*}],
            tools: [:show_counter, :list_items, :show_guarded],
            mcp_resources: [:counter, :static, :guarded]
          ],
          opts
        )
      )

    conn =
      Plug.Test.conn(:post, "/", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      })
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      # The MCP server derives its URL from the request's `host` header.
      |> then(&%{&1 | req_headers: [{"host", "www.example.com"} | &1.req_headers]})
      |> then(&if(actor, do: Ash.PlugHelpers.set_actor(&1, actor), else: &1))

    conn =
      try do
        AshAi.Mcp.Router.call(conn, router_opts)
      rescue
        error in Plug.Conn.WrapperError -> reraise error.reason, error.stack
      end

    Jason.decode!(conn.resp_body)
  end
end
