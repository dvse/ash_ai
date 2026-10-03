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

      for name <- ["counter_page", "counter_page_increment", "item_toggle"] do
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

    test "tools that are not the view's carry no page" do
      result = call("list_items", %{}, @alice)
      refute result["_meta"]["ash_ai/page"]
    end
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
