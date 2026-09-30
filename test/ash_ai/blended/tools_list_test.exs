# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.ToolsListTest do
  @moduledoc """
  The `tools/list` shape of the BLENDED additions: `title`, `annotations` (BLENDED-009),
  `description` with example and blocking marker (BLENDED-003/005), `_meta` hyperbob keys
  (BLENDED-005/006), `outputSchema` (BLENDED-010), `refine?` (BLENDED-004) and zero-input
  schemas (BLENDED-011).
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshAi.Mcp.Router
  alias AshAi.Test.Blended.{Author, Comment, Post}

  @opts [actions: [{Post, :*}, {Author, :*}, {Comment, :*}], actor: %{admin: true}]

  setup_all do
    %{tools: list_tools(@opts)}
  end

  describe "tools/list entry" do
    test "every entry has the MCP tool fields", %{tools: tools} do
      for {name, tool} <- tools do
        assert tool["name"] == name
        assert is_binary(tool["title"])
        assert is_binary(tool["description"])
        assert %{"type" => "object"} = tool["inputSchema"]

        assert %{
                 "readOnlyHint" => read_only,
                 "destructiveHint" => destructive,
                 "idempotentHint" => idempotent,
                 "openWorldHint" => open_world
               } = tool["annotations"]

        assert Enum.all?([read_only, destructive, idempotent, open_world], &is_boolean/1)
      end
    end

    test "title comes from annotations.title, else the tool or interface name", %{tools: tools} do
      assert tools["create_post"]["title"] == "Create a post"
      assert tools["create_post"]["annotations"]["title"] == "Create a post"
      assert tools["list_posts"]["title"] == "list_posts"
      refute Map.has_key?(tools["list_posts"]["annotations"], "title")
      assert tools["publish_post"]["title"] == "publish_post"
    end
  end

  describe "BLENDED-009 annotation defaults" do
    test "read: read-only, not destructive", %{tools: tools} do
      assert hints(tools["list_posts"]) == {true, false, false, false}
      assert hints(tools["get_post"]) == {true, false, false, false}
    end

    test "create: neither read-only nor destructive", %{tools: tools} do
      assert hints(tools["create_author"]) == {false, false, false, false}
    end

    test "update and destroy: destructive", %{tools: tools} do
      assert hints(tools["update_post"]) == {false, true, false, false}
      assert hints(tools["destroy_post"]) == {false, true, false, false}
      assert hints(tools["rename_author"]) == {false, true, false, false}
    end

    test "generic: destructive, not read-only", %{tools: tools} do
      assert hints(tools["stats"]) == {false, true, false, false}
      assert hints(tools["protected"]) == {false, true, false, false}
    end

    test "action metadata carriers override the type default", %{tools: tools} do
      # `read :search` declares `metadata :read_only?, :boolean, default: false`.
      assert hints(tools["search_posts"]) == {false, false, false, false}
      # `update :publish` declares `metadata :destructive?, :boolean, default: false`, and the
      # interface overrides `read_only?`.
      assert hints(tools["publish_post"]) == {true, false, false, false}
    end

    test "per-tool annotations override everything", %{tools: tools} do
      assert hints(tools["create_post"]) == {false, false, true, true}
    end
  end

  describe "BLENDED-003/005 description" do
    test "an example is appended to the description", %{tools: tools} do
      assert tools["create_post"]["description"] ==
               "Call the create tool\n\nExample:\n{\"input\": {\"title\": \"Hello\"}}"

      assert tools["publish_post"]["description"] ==
               "Publishes a post.\n\nExample:\n{\"id\": \"...\", \"input\": {\"title\": \"Final\"}}"
    end

    test "blocking tools say so; a timeout_ms argument bounds the wait", %{tools: tools} do
      assert tools["wait_for"]["description"] ==
               "Call the wait_for tool\n\nBlocking. This call waits up to its own timeout_ms, which defaults per action."

      # A generic action named `:await`.
      assert tools["await_now"]["description"] == "Call the await tool\n\nBlocking."
      # An interface named `:await` over `:wait_for`.
      assert tools["await"]["description"] =~ "Blocking. This call waits up to its own timeout_ms"
      # `metadata :blocking?` defaulting to a function returning true.
      assert tools["search_posts"]["description"] == "Call the search tool\n\nBlocking."
    end

    test "non-blocking tools carry no marker", %{tools: tools} do
      # `metadata :blocking?, default: true`, overridden by `blocking?: false`.
      refute tools["await_posts"]["description"] =~ "Blocking"
      # `metadata :blocking?` declared without a default.
      refute tools["create_post"]["description"] =~ "Blocking"
      refute tools["list_comments"]["description"] =~ "Blocking"
    end

    test "an empty example adds nothing" do
      tool = tool(:list_comments)
      assert AshAi.Tools.description(%{tool | example: ""}) == "Call the read tool"

      assert AshAi.Tools.description(%{tool | example: "  x  "}) ==
               "Call the read tool\n\nExample:\nx"
    end
  end

  describe "BLENDED-005/006 _meta" do
    test "hyperbob keys are merged into _meta only when set", %{tools: tools} do
      assert tools["await_now"]["_meta"] == %{
               "hyperbob/blocking" => true,
               "hyperbob/continuation_target" => true
             }

      assert tools["wait_for"]["_meta"] == %{"hyperbob/blocking" => true}
      refute Map.has_key?(tools["list_comments"], "_meta")
      refute Map.has_key?(tools["await_posts"], "_meta")
    end

    test "upstream _meta is kept" do
      tool = %{tool(:list_comments) | _meta: %{"openai/x" => "y"}, blocking?: true}
      assert AshAi.Tool.meta(tool) == %{"openai/x" => "y", "hyperbob/blocking" => true}
      assert AshAi.Tool.meta(%{tool | _meta: nil}) == %{"hyperbob/blocking" => true}
    end
  end

  describe "BLENDED-010 outputSchema" do
    test "object-shaped tools advertise an outputSchema", %{tools: tools} do
      for name <- ~w(create_post update_post destroy_post get_post stats pick summary publish_post
                     offset_posts keyset_posts both_posts select_posts) do
        assert %{"type" => "object"} = tools[name]["outputSchema"], name
      end
    end

    test "tools that may return a non-object advertise none", %{tools: tools} do
      for name <- ~w(list_posts plain_posts count_posts scalar numbers maybe nothing price
                     mood_now search_posts stats_no_schema) do
        refute Map.has_key?(tools[name], "outputSchema"), name
      end
    end

    test "record schemas list selected and loaded fields", %{tools: tools} do
      %{"anyOf" => [%{"properties" => %{"results" => %{"items" => record}}} | _]} =
        tools["select_posts"]["outputSchema"]

      assert Map.keys(record["properties"]) == ["internal", "title"]
      assert record["additionalProperties"] == false

      get_post = tools["get_post"]["outputSchema"]
      assert get_post["properties"]["score"] == %{"type" => "string"}
      assert get_post["properties"]["author"]["properties"]["name"] == %{"type" => "string"}
      assert get_post["properties"]["secret"] == %{"type" => "string"}
    end

    test "names that are not fields are skipped, as the serializer skips them" do
      tool = %{tool(:get_post) | select: [:title, :no_such_field]}

      assert Map.keys(AshAi.Tool.Schema.output_for_tool(tool)["properties"]) == [
               "author",
               "title"
             ]
    end

    test "a load function leaves the record open", %{tools: tools} do
      %{"anyOf" => [%{"properties" => %{"results" => %{"items" => record}}} | _]} =
        tools["dynamic_posts"]["outputSchema"]

      refute Map.has_key?(record, "additionalProperties")
    end
  end

  describe "BLENDED-004 refine?" do
    test "refine?: false omits the read query envelope", %{tools: tools} do
      properties = tools["select_posts"]["inputSchema"]["properties"]

      for key <- ~w(filter sort limit result_type) do
        refute Map.has_key?(properties, key)
      end

      # `:read` is paginated, so its page controls stay.
      assert Map.keys(properties) == ["after", "before", "offset"]

      assert tools["select_posts"]["inputSchema"] == tools["none_posts"]["inputSchema"]
    end

    test "paginated reads keep their page controls", %{tools: tools} do
      assert Map.keys(tools["offset_posts"]["inputSchema"]["properties"]) == ["offset"]
      assert Map.keys(tools["keyset_posts"]["inputSchema"]["properties"]) == ["after", "before"]
    end

    test "refine?: true keeps the envelope", %{tools: tools} do
      assert Map.has_key?(tools["list_posts"]["inputSchema"]["properties"], "filter")
    end

    test "an interface with refine?: false has no envelope either", %{tools: tools} do
      assert Map.keys(tools["post_by_title"]["inputSchema"]["properties"]) == ["title"]
    end
  end

  describe "BLENDED-011 zero-input" do
    test "tools with no required input require nothing", %{tools: tools} do
      assert tools["stats"]["inputSchema"]["required"] == []
      assert tools["list_posts"]["inputSchema"]["required"] == []
      # Inputs exist, but none is required.
      assert Map.has_key?(tools["update_post"]["inputSchema"]["properties"], "input")
      assert tools["update_post"]["inputSchema"]["required"] == []
    end

    test "tools with required input still require it", %{tools: tools} do
      assert tools["needs_input"]["inputSchema"]["required"] == ["input"]
      assert tools["needs_input"]["inputSchema"]["properties"]["input"]["required"] == ["name"]
      assert tools["create_post"]["inputSchema"]["required"] == ["input"]
      assert tools["get_post"]["inputSchema"]["required"] == ["id"]
    end

    test "strict mode keeps making every property required" do
      strict = @opts |> Keyword.put(:strict, true) |> list_tools()
      assert strict["update_post"]["inputSchema"]["required"] |> Enum.sort() == ["id", "input"]
    end
  end

  describe "AshAi.Tool helpers" do
    test "explicit annotations and blocking? win over metadata and type" do
      tool = %{
        tool(:search_posts)
        | annotations: [read_only?: true, destructive?: true],
          blocking?: false
      }

      assert %{read_only?: true, destructive?: true} = AshAi.Tool.annotations(tool)
      refute AshAi.Tool.blocking?(tool)
    end

    test "a CRUD action named like an await interface is not blocking without metadata" do
      # Faithful to ash_hyperlang: actions that carry `metadata` are judged by it alone.
      refute AshAi.Tool.blocking?(%{tool(:list_comments) | interface: :await})
    end

    test "nil annotations behave like none" do
      assert %{title: nil, read_only?: true} =
               AshAi.Tool.annotations(%{tool(:list_comments) | annotations: nil})

      assert AshAi.Tool.title(%{tool(:list_comments) | annotations: nil}) == "list_comments"
    end
  end

  defp hints(tool) do
    %{
      "readOnlyHint" => read_only,
      "destructiveHint" => destructive,
      "idempotentHint" => idempotent,
      "openWorldHint" => open_world
    } = tool["annotations"]

    {read_only, destructive, idempotent, open_world}
  end

  defp tool(name) do
    @opts |> AshAi.exposed_tools() |> Enum.find(&(&1.name == name))
  end

  defp list_tools(opts) do
    conn(:post, "/", %{"method" => "tools/list", "id" => "list"})
    |> Router.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
    |> get_in(["result", "tools"])
    |> Map.new(&{&1["name"], &1})
  end
end
