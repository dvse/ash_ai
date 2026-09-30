# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.ToolsCallTest do
  @moduledoc """
  The `tools/call` behaviour of the BLENDED additions: result hints (BLENDED-007), delivery
  hints (BLENDED-008), zero-input calls (BLENDED-011), forbidden-field rendering
  (BLENDED-012) and the policy breakdown (BLENDED-013).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import ExUnit.CaptureLog

  alias AshAi.Mcp.Router
  alias AshAi.Test.Blended
  alias AshAi.Test.Blended.{Author, Comment, Post}

  @actions [{Post, :*}, {Author, :*}, {Comment, :*}]
  @opts [actions: @actions, actor: %{admin: false}]

  setup do
    post =
      Ash.create!(Post, %{title: "Hello", secret: "hunter2", score: Decimal.new("1.5")},
        authorize?: false
      )

    %{post: post}
  end

  describe "BLENDED-007 hints" do
    test "a string hint is appended as a second text block; structuredContent is unchanged" do
      result = call(@opts, "create_post", %{"input" => %{"title" => "Fresh"}})

      assert [%{"type" => "text", "text" => json}, %{"type" => "text", "text" => hint}] =
               result["content"]

      assert hint == "Created Fresh. Publish it with publish_post."
      assert result["structuredContent"] == Jason.decode!(json)
      refute Map.has_key?(result["structuredContent"], "hint")
    end

    test "a nil, non-string, raising or throwing hint adds nothing" do
      for name <- ~w(stats summary post_record address) do
        assert %{"isError" => false, "content" => [_only]} = call(@opts, name, %{}), name
      end
    end

    test "hints only see map results" do
      # `scalar` has a hints function, but its raw result is a string.
      assert %{"content" => [%{"text" => "\"scalar\""}]} = call(@opts, "scalar", %{})
    end

    test "errors carry no hint" do
      assert %{"isError" => true, "content" => [_only]} =
               call(@opts, "create_post", %{"input" => %{"title" => nil}})
    end
  end

  describe "BLENDED-015 hints and delivery hints as modules" do
    test "a hints module, with or without options, appends its text" do
      assert %{"content" => [_json, %{"type" => "text", "text" => "Totals: 3."}]} =
               call(@opts, "stats_hinted", %{})

      assert %{"content" => [_json, %{"type" => "text", "text" => "Total: 3."}]} =
               call(@opts, "stats_module_hint", %{})
    end

    test "a delivery_hints module receives its options" do
      result = call(@opts, "create_author", %{"input" => %{"name" => "Zed"}})
      assert result["_meta"]["hyperbob/delivery_hints"] == [%{"note" => "Write their first post"}]

      author = Ash.create!(AshAi.Test.Blended.Author, %{name: "Yan"}, authorize?: false)
      refute Map.has_key?(call(@opts, "author_by_id", %{"id" => author.id}), "_meta")
    end
  end

  describe "BLENDED-008 delivery hints" do
    test "hint maps render as calls to exposed tools, else as notes" do
      result = call(@opts, "create_post", %{"input" => %{"title" => "Fresh"}})

      assert result["_meta"]["hyperbob/delivery_hints"] == [
               %{
                 "tool" => "publish_post",
                 "arguments" => %{"input" => %{"title" => "Published"}},
                 "note" => "Publish it"
               },
               %{
                 "tool" => "update_post",
                 "arguments" => %{"input" => %{}},
                 "note" => "Or rename it"
               },
               %{"note" => "Just a note"},
               %{"tool" => "author_by_id", "arguments" => %{"input" => %{}}}
             ]
    end

    test "no hint survives rendering, or none are returned: no _meta key", %{post: post} do
      # `update_post` returns only an unmatched hint without a note.
      result = call(@opts, "update_post", %{"id" => post.id, "input" => %{"body" => "b"}})
      assert result["isError"] == false
      refute Map.has_key?(result, "_meta")

      # `list_comments` has no expose on Comment.
      refute Map.has_key?(call(@opts, "list_comments", %{}), "_meta")
      # The Post callback returns nil for other tools.
      refute Map.has_key?(call(@opts, "list_posts", %{}), "_meta")
    end

    test "a non-list or raising callback is logged and ignored", %{post: post} do
      log =
        capture_log(fn ->
          result = call(@opts, "destroy_post", %{"id" => post.id})
          assert result["isError"] == false
          refute Map.has_key?(result, "_meta")
        end)

      assert log =~ "delivery_hints for AshAi.Test.Blended.Post returned a non-list value"

      other = Ash.create!(Post, %{title: "Other"}, authorize?: false)

      log =
        capture_log(fn ->
          result = call(@opts, "get_post", %{"id" => other.id})
          assert result["isError"] == false
          refute Map.has_key?(result, "_meta")
        end)

      assert log =~ "delivery_hints for AshAi.Test.Blended.Post failed: delivery hints failed"
    end
  end

  describe "BLENDED-011 zero-input" do
    test "a tool with no required input accepts {} and missing arguments" do
      assert %{"isError" => false, "structuredContent" => %{"total" => 3}} =
               call(@opts, "stats", %{})

      assert %{"isError" => false, "structuredContent" => %{"total" => 3}} =
               call_without_arguments(@opts, "stats")
    end

    test "a tool with required input still rejects {}" do
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               call(@opts, "needs_input", %{})

      assert text =~ "name"
    end
  end

  describe "BLENDED-012 forbidden fields" do
    test ":hide (the default) omits forbidden fields" do
      assert %{"results" => [record]} = call(@opts, "list_posts", %{})["structuredContent"]
      assert record["title"] == "Hello"
      refute Map.has_key?(record, "secret")
    end

    test "a resource-level :display renders the opaque marker" do
      assert %{"results" => [record]} =
               call(@opts, "resource_list_posts", %{})["structuredContent"]

      assert record["secret"] == %{"opaque" => "forbidden"}
    end

    test "allowed fields render normally" do
      admin = Keyword.put(@opts, :actor, %{admin: true})

      assert %{"results" => [%{"secret" => "hunter2"}]} =
               call(admin, "resource_list_posts", %{})["structuredContent"]
    end

    test "the MCP server option overrides the DSL, in results and in outputSchema", %{post: post} do
      display = Keyword.put(@opts, :forbidden_fields, :display)
      hide = Keyword.put(@opts, :forbidden_fields, :hide)

      assert %{"secret" => %{"opaque" => "forbidden"}} =
               call(display, "get_post", %{"id" => post.id})["structuredContent"]

      assert %{"results" => [record]} =
               call(hide, "resource_list_posts", %{})["structuredContent"]

      refute Map.has_key?(record, "secret")

      assert %{"anyOf" => [%{"type" => "string"}, marker]} =
               list_tools(display)["get_post"]["outputSchema"]["properties"]["secret"]

      assert marker["properties"] == %{"opaque" => %{"type" => "string", "enum" => ["forbidden"]}}

      assert list_tools(hide)["get_post"]["outputSchema"]["properties"]["secret"] == %{
               "type" => "string"
             }
    end

    test "nested records render the marker too", %{post: post} do
      Ash.create!(Comment, %{body: "c", post_id: post.id}, domain: Blended)
      display = Keyword.put(@opts, :forbidden_fields, :display)

      # `list_posts` loads `comments: [post: []]`.
      assert %{"results" => [record]} = call(display, "list_posts", %{})["structuredContent"]
      assert [%{"post" => %{"secret" => %{"opaque" => "forbidden"}}}] = record["comments"]
    end
  end

  describe "BLENDED-013 policy breakdown" do
    test "an anonymous caller gets a compact denial and a www_authenticate challenge" do
      opts = Keyword.put(@opts, :actor, nil)

      log =
        capture_log(fn ->
          result = call(opts, "protected", %{})

          assert result["isError"] == true

          assert result["content"] == [
                   %{
                     "type" => "text",
                     "text" =>
                       "access denied: tool protected, action protected on resource Post (policy_denied)"
                   }
                 ]

          assert result["_meta"] == %{
                   "mcp/www_authenticate" => [
                     ~s|Bearer error="insufficient_scope", error_description="access denied: tool protected, action protected on resource Post (policy_denied)"|
                   ]
                 }
        end)

      assert log =~ "AshAi tool call denied"
      assert log =~ "tool=protected"
      assert log =~ "Policy Breakdown"
      assert log =~ "condition: action in [:protected, :protected_create]"
    end

    test "the challenge names the resource metadata URL when configured" do
      opts =
        @opts
        |> Keyword.put(:actor, nil)
        |> Keyword.put(
          :resource_metadata_url,
          "https://example.com/.well-known/oauth-protected-resource"
        )

      capture_log(fn ->
        assert [challenge] =
                 call(opts, "protected_create", %{"input" => %{"title" => "x"}})["_meta"][
                   "mcp/www_authenticate"
                 ]

        assert challenge =~
                 ~s|Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource", error="insufficient_scope"|
      end)
    end

    test "a signed-in caller gets the compact denial without a challenge" do
      capture_log(fn ->
        result = call(@opts, "protected", %{})

        assert %{"isError" => true, "content" => [%{"text" => text}]} = result

        assert text ==
                 "access denied: tool protected, action protected on resource Post (policy_denied)"

        refute Map.has_key?(result, "_meta")
      end)
    end

    test "a forbidden error without policy failures keeps upstream's text" do
      # A field-policy-forbidden aggregate raises `%Ash.Error.Forbidden{errors: []}`.
      result =
        call(@opts, "list_posts", %{"result_type" => %{"aggregate" => "max", "field" => "secret"}})

      assert %{"isError" => true, "content" => [%{"text" => "Tool execution failed"}]} = result
      refute Map.has_key?(result, "_meta")
    end

    test "outside MCP, policy errors keep upstream's text" do
      tool = Enum.find(AshAi.exposed_tools(@opts), &(&1.name == :protected))

      assert {:error, "forbidden"} =
               AshAi.Tools.execute(tool, %{}, %{actor: nil, tenant: nil, context: %{}})
    end
  end

  describe "tools built outside AshAi.exposed_tools/1" do
    test "an unset forbidden_fields means :hide", %{post: post} do
      tool = Enum.find(AshAi.exposed_tools(@opts), &(&1.name == :resource_list_posts))
      tool = %{tool | forbidden_fields: nil}

      assert {:ok, %{"results" => [record]}, _raw} =
               AshAi.Tools.execute(tool, %{}, %{actor: %{admin: false}}, encode?: false)
               |> then(fn {:ok, value, raw} ->
                 {:ok, Jason.decode!(Jason.encode!(value)), raw}
               end)

      assert record["id"] == post.id
      refute Map.has_key?(record, "secret")

      get_post = Enum.find(AshAi.exposed_tools(@opts), &(&1.name == :get_post))

      assert AshAi.Tool.Schema.output_for_tool(%{get_post | forbidden_fields: nil})["properties"][
               "secret"
             ] ==
               %{"type" => "string"}
    end
  end

  defp call(opts, name, arguments) do
    request(opts, %{"name" => name, "arguments" => arguments})
  end

  defp call_without_arguments(opts, name), do: request(opts, %{"name" => name})

  defp request(opts, params) do
    conn(:post, "/", %{"method" => "tools/call", "id" => "call", "params" => params})
    |> Router.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
    |> Map.fetch!("result")
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
