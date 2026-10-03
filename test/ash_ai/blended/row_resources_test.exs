# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.RowResourcesTest do
  @moduledoc """
  BLENDED-022: `mcp_resource_template` — one MCP resource per row. `resources/templates/list`
  lists the template, `resources/list` the rows the list action returns for the caller, and
  `resources/read` reads the row as the caller before running the action with the URI's values.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshAi.McpResourceTemplate
  alias AshAi.Test.RowResources.{Doc, NoPrimary}
  alias AshAi.Verifiers.VerifyMcpResourceTemplates

  @alice %{name: "alice"}
  @bob %{name: "bob"}

  setup do
    for doc <- Ash.read!(Doc, action: :everything), do: Ash.destroy!(doc)
    for number <- Ash.read!(NoPrimary, action: :all), do: Ash.destroy!(number, action: :destroy)

    Ash.create!(Doc, %{id: "a1", title: "Alpha", summary: "The first.", owner: "alice", body: "A"})

    Ash.create!(Doc, %{id: "a b/c", title: "Spaced", owner: "alice", body: "S"})
    Ash.create!(Doc, %{id: "b1", owner: "bob", body: "B"})
    :ok
  end

  describe "declaration" do
    test "the test domain verifies" do
      assert :ok = VerifyMcpResourceTemplates.verify(AshAi.Test.RowResources.spark_dsl_config())
    end

    test "a template without a variable, or with an expression that is not one, is refused" do
      assert refusal(~s(mcp_resource_template :x, "docs://x", Doc, :markdown, title: "X")) ==
               ~s(mcp_resource_template :x uri template "docs://x" has no {variable})

      assert refusal(~s(mcp_resource_template :x, "docs://{+id}", Doc, :markdown, title: "X")) ==
               ~s(mcp_resource_template :x uri template "docs://{+id}" has {+id}, which is not a simple {variable})

      assert refusal(~s(mcp_resource_template :x, "docs://{id}}", Doc, :markdown, title: "X")) ==
               ~s(mcp_resource_template :x uri template "docs://{id}}" has an unbalanced brace)

      assert refusal(~s(mcp_resource_template :x, "d://{id}/{id}", Doc, :markdown, title: "X")) ==
               ~s(mcp_resource_template :x uri template "d://{id}/{id}" repeats a variable)
    end

    test "a template with no literal between two variables is refused" do
      assert refusal(
               ~s(mcp_resource_template :x, "docs://{owner}{id}", Doc, :by_owner, title: "X")
             ) ==
               ~s(mcp_resource_template :x uri template "docs://{owner}{id}" has {owner}{id}: no literal separates the two variables)

      assert McpResourceTemplate.variables("a://{x}{y}/{z}") ==
               {:error, "has {x}{y}: no literal separates the two variables"}

      assert McpResourceTemplate.variables("a://{x}-{y}") == {:ok, ["x", "y"]}
    end

    test "a variable that is not a public attribute, or not an argument of the action, is refused" do
      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}/{secret}", Doc, :markdown, title: "X")
             ) ==
               "mcp_resource_template :x variable {secret} is not an argument of action :markdown"

      assert refusal(
               ~s(mcp_resource_template :x, "docs://{owner}/{id}", Doc, :markdown, title: "X")
             ) ==
               "mcp_resource_template :x variable {owner} is not an argument of action :markdown"

      assert refusal(
               ~s(mcp_resource_template :x, "docs://{nope}/{id}", Doc, :by_owner, title: "X")
             ) ==
               "mcp_resource_template :x variable {nope} is not an argument of action :by_owner"
    end

    test "an action that is not generic, or returns neither string nor binary, is refused" do
      assert refusal(~s(mcp_resource_template :x, "docs://{id}", Doc, :read, title: "X")) ==
               "mcp_resource_template :x action :read is not a generic action of AshAi.Test.RowResources.Doc"

      assert refusal(~s(mcp_resource_template :x, "docs://{id}", Doc, :nope, title: "X")) ==
               "mcp_resource_template :x action :nope is not a generic action of AshAi.Test.RowResources.Doc"

      assert refusal(~s(mcp_resource_template :x, "docs://{id}", Doc, :as_map, title: "X")) ==
               "mcp_resource_template :x action :as_map must return :string or :binary"
    end

    test "a list that is not a read action, or a row option that is not public, is refused" do
      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}", Doc, :markdown, title: "X", list: :markdown)
             ) ==
               "mcp_resource_template :x list :markdown is not a read action of AshAi.Test.RowResources.Doc"

      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}", Doc, :markdown, title: "X", row_title: :secret)
             ) ==
               "mcp_resource_template :x row_title :secret is not a public attribute of AshAi.Test.RowResources.Doc"

      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}", Doc, :markdown, title: "X", row_name: :nope)
             ) ==
               "mcp_resource_template :x row_name :nope is not a public attribute of AshAi.Test.RowResources.Doc"
    end

    test "a variable that is an argument but not a public attribute is refused" do
      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}/{style}", Doc, :markdown, title: "X")
             ) ==
               "mcp_resource_template :x variable {style} is not a public attribute of AshAi.Test.RowResources.Doc"
    end

    test "a list action without a pagination default_limit is refused: the listing is bounded" do
      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}", Doc, :markdown, title: "X", list: :unbounded)
             ) ==
               "mcp_resource_template :x list :unbounded has no pagination default_limit: resources/list would list every row"

      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}", Doc, :markdown, title: "X", list: :no_default)
             ) ==
               "mcp_resource_template :x list :no_default has no pagination default_limit: resources/list would list every row"

      assert refusal(~s(mcp_resource_template :x, "l://{id}", Loose, :show, title: "X")) ==
               "mcp_resource_template :x lists through the primary read :read, whose pagination has no default_limit: " <>
                 "resources/list would list every row; declare list: a read action with one"

      assert refusal(
               ~s(mcp_resource_template :x, "docs://{id}", Doc, :markdown, title: "X", list: :first_two)
             ) == :ok
    end

    test "a resource without a primary read needs a list action" do
      assert refusal(~s(mcp_resource_template :x, "n://{id}", NoPrimary, :show, title: "X")) ==
               "mcp_resource_template :x has no list action and AshAi.Test.RowResources.NoPrimary has no primary read action"

      assert refusal(
               ~s(mcp_resource_template :x, "n://{id}", NoPrimary, :show, title: "X", list: :all)
             ) == :ok
    end

    test "the refusal is reported when the domain compiles" do
      output =
        capture_io(:stderr, fn ->
          domain(~s(mcp_resource_template :x, "docs://x", Doc, :markdown, title: "X"))
        end)

      assert output =~ ~s(mcp_resource_template :x uri template "docs://x" has no {variable})
    end

    test "templates are introspectable apart from the other resources" do
      assert [:doc, :owned, :bytes, :broken, :everyone, :first_two, :number] ==
               AshAi.Test.RowResources
               |> AshAi.Info.mcp_resource_templates()
               |> Enum.map(& &1.name)

      assert AshAi.Info.mcp_action_resources(AshAi.Test.RowResources) == []
    end
  end

  describe "the URI template" do
    test "expands with percent-encoded values and matches back" do
      template = "docs://owners/{owner}/docs/{id}"
      values = %{"owner" => "al ice", "id" => "a b/c"}
      uri = McpResourceTemplate.expand(template, values)

      assert uri == "docs://owners/al%20ice/docs/a%20b%2Fc"
      assert McpResourceTemplate.match(template, uri) == {:ok, values}
      assert McpResourceTemplate.expand(template, %{"owner" => "x", "id" => nil}) == nil
    end

    test "matches only the whole URI, one segment per variable" do
      assert McpResourceTemplate.match("docs://docs/{id}", "docs://docs/a/b") == :error
      assert McpResourceTemplate.match("docs://docs/{id}", "docs://docs/") == :error
      assert McpResourceTemplate.match("docs://docs/{id}", "xdocs://docs/a") == :error
      assert McpResourceTemplate.match("docs://docs/{id}", "docs://docs/%zz") == :error
      assert McpResourceTemplate.match("d.cs://{id}", "dxcs://a") == :error
      assert McpResourceTemplate.match("docs://docs/{id}", "docs://docs/a1\n") == :error
    end

    test "a variable a literal could end at several places takes the longest span" do
      assert McpResourceTemplate.match("x://{a}.{b}", "x://p.q.r") ==
               {:ok, %{"a" => "p.q", "b" => "r"}}

      assert McpResourceTemplate.match("x://{a}-{b}-{c}", "x://a-b-c-d-e") ==
               {:ok, %{"a" => "a-b-c", "b" => "d", "c" => "e"}}
    end

    test "matching a long URI takes time linear in its length" do
      dotted = String.duplicate("a.", 4000)

      {micros, result} =
        :timer.tc(fn -> McpResourceTemplate.match("x://{a}.{b}.{c}", "x://" <> dotted <> "!") end)

      assert result == :error
      assert micros < 1_000_000

      assert {:ok, %{"b" => "a", "c" => "a"}} =
               McpResourceTemplate.match("x://{a}.{b}.{c}", "x://" <> dotted <> "a")
    end
  end

  describe "resources/templates/list" do
    test "lists each exposed template" do
      assert %{"result" => %{"resourceTemplates" => templates}} =
               rpc("resources/templates/list", nil, @alice)

      assert templates == [
               %{
                 "uriTemplate" => "docs://all/{id}",
                 "name" => "everyone",
                 "title" => "Every document",
                 "description" => "A document as Markdown.",
                 "mimeType" => "text/plain"
               },
               %{
                 "uriTemplate" => "docs://broken/{id}",
                 "name" => "broken",
                 "title" => "Broken",
                 "mimeType" => "text/plain"
               },
               %{
                 "uriTemplate" => "docs://bytes/{id}",
                 "name" => "bytes",
                 "title" => "Document bytes",
                 "mimeType" => "application/octet-stream"
               },
               %{
                 "uriTemplate" => "docs://docs/{id}",
                 "name" => "doc",
                 "title" => "Document",
                 "description" => "A document as Markdown.",
                 "mimeType" => "text/markdown"
               },
               %{
                 "uriTemplate" => "docs://first/{id}",
                 "name" => "first_two",
                 "title" => "First two documents",
                 "description" => "A document as Markdown.",
                 "mimeType" => "text/plain"
               },
               %{
                 "uriTemplate" => "docs://owners/{owner}/docs/{id}",
                 "name" => "owned",
                 "title" => "Owned document",
                 "description" => "A document under its owner.",
                 "mimeType" => "text/plain"
               }
             ]
    end

    test "the mcp_resources option and exclude_actions select templates" do
      assert %{"result" => %{"resourceTemplates" => [%{"name" => "doc"}]}} =
               rpc("resources/templates/list", nil, @alice, mcp_resources: [:doc])

      assert %{"result" => %{"resourceTemplates" => templates}} =
               rpc("resources/templates/list", nil, @alice,
                 exclude_actions: [{Doc, :markdown}, {Doc, :bytes}]
               )

      assert Enum.map(templates, & &1["name"]) == ["broken", "owned"]
    end

    test "every server answers, with no templates an empty list" do
      assert rpc("resources/templates/list", nil, @alice, mcp_resources: [])["result"] ==
               %{"resourceTemplates" => []}
    end

    test "a server with only templates has the resources capability, without listChanged" do
      assert %{"result" => %{"capabilities" => capabilities}} =
               rpc("initialize", %{"protocolVersion" => "2025-06-18"}, @alice,
                 mcp_resources: [:doc]
               )

      assert capabilities["resources"] == %{}

      assert %{"result" => %{"capabilities" => capabilities}} =
               rpc("initialize", %{"protocolVersion" => "2025-06-18"}, @alice, mcp_resources: [])

      refute Map.has_key?(capabilities, "resources")
    end
  end

  describe "resources/list" do
    test "lists one resource per row the caller may read" do
      assert list(@alice, [:doc]) == [
               %{
                 "uri" => "docs://docs/a%20b%2Fc",
                 "name" => "a b/c",
                 "title" => "Spaced",
                 "mimeType" => "text/markdown"
               },
               %{
                 "uri" => "docs://docs/a1",
                 "name" => "a1",
                 "title" => "Alpha",
                 "description" => "The first.",
                 "mimeType" => "text/markdown"
               }
             ]

      assert list(@bob, [:doc]) == [
               %{"uri" => "docs://docs/b1", "name" => "b1", "mimeType" => "text/markdown"}
             ]

      assert list(nil, [:doc]) == []
    end

    test "rows come from the list action; without row_name the name is the URI" do
      assert list(@bob, [:owned]) == []

      assert Enum.map(list(@alice, [:owned]), &{&1["uri"], &1["name"]}) == [
               {"docs://owners/alice/docs/a%20b%2Fc", "docs://owners/alice/docs/a%20b%2Fc"},
               {"docs://owners/alice/docs/a1", "docs://owners/alice/docs/a1"}
             ]

      assert Enum.map(list(@bob, [:everyone]), & &1["uri"]) ==
               ["docs://all/a%20b%2Fc", "docs://all/a1", "docs://all/b1"]
    end

    test "the listing reads one page of the list action's default_limit rows" do
      assert Enum.map(list(@bob, [:first_two]), & &1["uri"]) ==
               ["docs://first/a%20b%2Fc", "docs://first/a1"]

      assert {:ok, %{"text" => "# \n\nB\n\n(read by bob)"}} = read("docs://first/b1", @bob)
    end

    test "rows are listed beside the other resources, in URI order" do
      uris = Enum.map(list(@bob, :*), & &1["uri"])
      assert uris == Enum.sort(uris)
      assert "docs://bytes/b1" in uris
      refute "docs://bytes/a1" in uris
    end
  end

  describe "resources/read" do
    test "reads the row's content as the caller, with the URI's values as arguments" do
      assert read("docs://docs/a1", @alice) ==
               {:ok,
                %{
                  "uri" => "docs://docs/a1",
                  "mimeType" => "text/markdown",
                  "text" => "# Alpha\n\nA\n\n(read by alice)"
                }}

      assert {:ok, %{"text" => "# Spaced\n\nS\n\n(read by alice)"}} =
               read("docs://docs/a%20b%2Fc", @alice)

      assert read("docs://owners/alice/docs/a1", @alice) ==
               {:ok,
                %{
                  "uri" => "docs://owners/alice/docs/a1",
                  "mimeType" => "text/plain",
                  "text" => "alice/a1"
                }}
    end

    test "the read request's params reach the action's other arguments; the URI's values win" do
      assert {:ok, %{"text" => "# Alpha\n\nA\n\n(read by alice, terse)"}} =
               read("docs://docs/a1", @alice, %{"style" => "terse", "id" => "b1"})
    end

    test "a row the caller may not read is not found, though the action would render it" do
      assert read("docs://docs/a1", @bob) == {:error, -32_002}
      assert read("docs://docs/a1", nil) == {:error, -32_002}
      assert read("docs://docs/missing", @alice) == {:error, -32_002}
      assert read("docs://owners/bob/docs/a1", @alice) == {:error, -32_002}
      assert read("docs://owners/bob/docs/b1", @bob) == {:error, -32_002}
      assert read("docs://docs/a/1", @alice) == {:error, -32_002}

      assert {:ok, %{"text" => "# Alpha\n\nA\n\n(read by bob)"}} =
               read("docs://all/a1", @bob)
    end

    test "a value the field cannot hold names no row" do
      Ash.create!(NoPrimary, %{id: 7}, action: :create)

      opts = [actions: [{NoPrimary, :*}]]
      assert {:ok, %{"text" => "number 7"}} = read("numbers://7", nil, %{}, opts)
      assert read("numbers://8", nil, %{}, opts) == {:error, -32_002}
      assert read("numbers://seven", nil, %{}, opts) == {:error, -32_002}
      assert read("numbers://7", nil) == {:error, -32_002}
    end

    test "a binary result is blob contents" do
      assert read("docs://bytes/b1", @bob) ==
               {:ok,
                %{
                  "uri" => "docs://bytes/b1",
                  "mimeType" => "application/octet-stream",
                  "blob" => Base.encode64(<<0, 255, "b1">>)
                }}
    end

    test "an action error is a read failure" do
      assert %{"error" => %{"code" => -32_603, "data" => %{"error" => error}}} =
               rpc("resources/read", %{"uri" => "docs://broken/a1"}, @alice)

      assert is_binary(error)
    end

    test "a template outside the mcp_resources option is not read" do
      assert read("docs://docs/a1", @alice, %{}, mcp_resources: [:owned]) == {:error, -32_002}
    end
  end

  describe "2026-07-28" do
    test "resources/templates/list and resources/read answer per request" do
      assert %{"result" => %{"resourceTemplates" => [%{"name" => "doc"}], "ttlMs" => _}} =
               versioned("resources/templates/list", %{}, @alice)

      assert %{"result" => %{"contents" => [%{"text" => "# Alpha\n\nA\n\n(read by alice)"}]}} =
               versioned("resources/read", %{"uri" => "docs://docs/a1"}, @alice)

      assert %{"error" => %{"code" => -32_602, "message" => "Resource not found"}} =
               versioned("resources/read", %{"uri" => "docs://docs/a1"}, @bob)
    end
  end

  defp refusal(entity) do
    capture_io(:stderr, fn -> send(self(), {:domain, domain(entity)}) end)
    assert_received {:domain, module}

    case VerifyMcpResourceTemplates.verify(module.spark_dsl_config()) do
      :ok -> :ok
      {:error, %Spark.Error.DslError{message: message}} -> message
    end
  end

  defp domain(entity) do
    module = Module.concat(__MODULE__, :"Domain#{System.unique_integer([:positive])}")

    Module.create(
      module,
      Code.string_to_quoted!("""
      use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false
      alias AshAi.Test.RowResources.{Doc, Loose, NoPrimary}

      resources do
        resource Doc
        resource NoPrimary
        resource Loose
      end

      mcp_resources do
        #{entity}
      end
      """),
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp list(actor, mcp_resources) do
    %{"result" => %{"resources" => resources}} =
      rpc("resources/list", nil, actor, mcp_resources: mcp_resources)

    resources
  end

  defp read(uri, actor, params \\ %{}, opts \\ []) do
    case rpc("resources/read", Map.put(params, "uri", uri), actor, opts) do
      %{"result" => %{"contents" => [content]}} -> {:ok, content}
      %{"error" => %{"code" => code}} -> {:error, code}
    end
  end

  defp rpc(method, params, actor, opts \\ []) do
    message =
      %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
      |> then(&if(params, do: Map.put(&1, "params", params), else: &1))

    actor
    |> conn(message, %{})
    |> AshAi.Mcp.Router.call(router_opts(opts))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp versioned(method, params, actor) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    headers =
      %{"mcp-protocol-version" => "2026-07-28", "mcp-method" => method}
      |> then(&if(params["uri"], do: Map.put(&1, "mcp-name", params["uri"]), else: &1))

    actor
    |> conn(
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => Map.put(params, "_meta", meta)
      },
      headers
    )
    |> AshAi.Mcp.Router.call(router_opts(mcp_resources: [:doc]))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp conn(actor, message, headers) do
    Plug.Test.conn(:post, "/", message)
    |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
    |> then(
      &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    )
    |> then(&if(actor, do: Ash.PlugHelpers.set_actor(&1, actor), else: &1))
  end

  defp router_opts(opts) do
    AshAi.Mcp.Router.init(Keyword.merge([otp_app: :ash_ai, actions: [{Doc, :*}]], opts))
  end
end
