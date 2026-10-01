# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.McpActionTest do
  @moduledoc """
  BLENDED-014: `AshAi.McpActions` synthesizes a public generic `:mcp` action that serves the
  MCP server through `Ash.run_action/2`, as the caller who invoked the action.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AshAi.McpActions.{Conn, Info}
  alias AshAi.Test.McpActions.{Endpoint, Note, PrivateEndpoint}

  @alice %{name: "alice"}
  @per_request "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @per_request,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  describe "the synthesized action" do
    test "exists, is public, takes a request map and returns a map" do
      for {resource, name} <- [{Endpoint, :mcp}, {PrivateEndpoint, :handle}] do
        assert Info.mcp_action_name(resource) == name
        action = Ash.Resource.Info.action(resource, name)
        assert %Ash.Resource.Actions.Action{type: :action, public?: true} = action
        assert action.returns == Ash.Type.Map
        assert [%{name: :request, type: Ash.Type.Map, allow_nil?: false}] = action.arguments
        assert action in Ash.Resource.Info.public_actions(resource)
      end
    end

    test "a resource compiled at runtime gets its named action" do
      # Compiled inside the test so the extension and transformer run under `mix test --cover`.
      defmodule RuntimeEndpoint do
        @moduledoc false
        use Ash.Resource, domain: AshAi.Test.McpActions, extensions: [AshAi.McpActions]

        mcp_actions do
          mcp_action_name :serve
          actions [{AshAi.Test.McpActions.Note, :*}]
        end
      end

      assert %{type: :action, public?: true} = Ash.Resource.Info.action(RuntimeEndpoint, :serve)
      refute Ash.Resource.Info.action(RuntimeEndpoint, :mcp)
    end

    test "the section's options become server options; otp_app defaults to the domain's" do
      assert Info.server_options(Endpoint) == [
               otp_app: :ash_ai,
               actions: [{Note, :*}],
               mcp_name: "notes",
               mcp_server_version: "1.2.3",
               instructions: "Use the notes tools."
             ]

      assert Keyword.take(Info.server_options(PrivateEndpoint), [:otp_app, :strict, :cache_scope]) ==
               [otp_app: :ash_ai, strict: true, cache_scope: "public"]
    end
  end

  describe "initialize-based requests through Ash.run_action" do
    test "initialize answers with the configured server and a session id" do
      assert %{status: 200, headers: headers, body: body} =
               mcp(%{"method" => "initialize", "id" => 1, "params" => %{}}, @alice)

      assert headers["content-type"] == "application/json"
      assert is_binary(headers["mcp-session-id"])

      assert %{
               "id" => 1,
               "result" => %{
                 "serverInfo" => %{"name" => "notes", "version" => "1.2.3"},
                 "protocolVersion" => "2025-06-18",
                 "instructions" => "Use the notes tools.",
                 "capabilities" => %{"tools" => %{}, "resources" => %{}}
               }
             } = Jason.decode!(body)
    end

    test "a session id header is kept" do
      assert %{headers: %{"mcp-session-id" => "session-1"}} =
               mcp(%{"method" => "initialize", "id" => 1, "params" => %{}}, @alice,
                 headers: %{"mcp-session-id" => "session-1"}
               )
    end

    test "tools/list is filtered for the action's actor and carries the blended fields" do
      signed_in = tool_names(@alice)
      assert signed_in == ["create_note", "guarded_note", "list_notes", "whoami"]

      # The guest does not see the create tool: its policy needs an actor (upstream pre-check).
      assert tool_names(nil) == ["guarded_note", "list_notes", "whoami"]

      %{"result" => %{"tools" => tools}} = rpc("tools/list", %{}, @alice)
      list = Enum.find(tools, &(&1["name"] == "list_notes"))
      create = Enum.find(tools, &(&1["name"] == "create_note"))

      assert list["title"] == "List notes"
      assert list["annotations"]["readOnlyHint"] == true
      assert create["title"] == "create_note"

      assert create["annotations"] == %{
               "readOnlyHint" => false,
               "destructiveHint" => false,
               "idempotentHint" => false,
               "openWorldHint" => false
             }

      assert create["outputSchema"]["type"] == "object"
      assert create["outputSchema"]["properties"]["owner"]
    end

    test "tools/call runs as the action's actor" do
      created = call("create_note", %{"input" => %{"title" => "Hello"}}, @alice)
      assert created["isError"] == false
      assert created["structuredContent"]["owner"] == "alice"
      assert created["structuredContent"]["title"] == "Hello"

      # The guest reads what alice created.
      assert %{"isError" => false, "structuredContent" => %{"results" => notes}} =
               call("list_notes", %{}, nil)

      assert [%{"title" => "Hello", "owner" => "alice"}] = notes

      assert %{"content" => [%{"text" => text}]} = call("whoami", %{}, %{name: "bob"})
      assert Jason.decode!(text) == %{"name" => "bob"}
    end

    test "a policy denial is a tool error; a tool hidden from the caller is not found" do
      log =
        capture_log(fn ->
          denied = call("guarded_note", %{"input" => %{"title" => "No"}}, @alice)
          assert denied["isError"] == true

          assert [%{"text" => text}] = denied["content"]
          assert text =~ "access denied: tool guarded_note"
          assert text =~ "(policy_denied)"
          refute Map.has_key?(denied, "_meta")
        end)

      assert log =~ "guarded_note"

      capture_log(fn ->
        guest = call("guarded_note", %{"input" => %{"title" => "No"}}, nil)

        assert ["Bearer error=\"insufficient_scope\"" <> _] =
                 guest["_meta"]["mcp/www_authenticate"]
      end)

      assert %{"error" => %{"code" => -32_602, "message" => "Tool not found: create_note"}} =
               rpc("tools/call", %{"name" => "create_note", "arguments" => %{}}, nil)
    end

    test "resources/read reads mcp_resource entries as the action's actor" do
      assert %{"result" => %{"contents" => [content]}} =
               rpc("resources/read", %{"uri" => "file://notes/card"}, @alice)

      assert content["text"] == "card for alice"
      assert content["mimeType"] == "text/plain"
    end

    test "server_url reaches the server" do
      %{"result" => %{"resources" => resources}} =
        rpc("resources/list", %{}, @alice, server_url: "https://notes.example/mcp")

      app = Enum.find(resources, &(&1["name"] == "note_app"))

      assert app["_meta"]["ui"]["domain"] ==
               AshAi.Mcp.Server.sandbox_domain("https://notes.example/mcp")
    end

    test "raw text is parsed by the server, and notifications answer 202" do
      assert %{status: 200, body: body} = mcp("{not json", @alice)
      assert %{"error" => %{"code" => -32_700}} = Jason.decode!(body)

      assert %{status: 202, body: ""} =
               mcp(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, @alice)
    end

    test "section options reach the server" do
      assert %{status: 200, body: body} =
               mcp(
                 %{
                   "method" => "initialize",
                   "id" => 1,
                   "params" => %{"protocolVersion" => "2025-06-18"}
                 },
                 @alice,
                 resource: PrivateEndpoint
               )

      assert %{"result" => %{"protocolVersion" => "2025-03-26"}} = Jason.decode!(body)

      %{"result" => %{"tools" => tools}} =
        rpc("tools/list", %{}, @alice, resource: PrivateEndpoint)

      # `tools` filters the tools; strict mode requires every property.
      assert Enum.map(tools, & &1["name"]) == ["create_note", "list_notes"]
      assert Enum.all?(tools, &(&1["inputSchema"]["additionalProperties"] == false))

      %{"result" => %{"resources" => resources}} =
        rpc("resources/list", %{}, @alice, resource: PrivateEndpoint)

      # `mcp_resources` and `exclude_actions` filter the resources.
      assert Enum.map(resources, & &1["name"]) == ["note_app"]
    end
  end

  describe "2026-07-28 requests through Ash.run_action" do
    test "headers are validated and carried per request" do
      message = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "whoami", "arguments" => %{}, "_meta" => @meta}
      }

      headers = %{
        "MCP-Protocol-Version" => @per_request,
        "mcp-method" => ["tools/call"],
        "mcp-name" => "whoami"
      }

      assert %{status: 200, body: body} = mcp(message, @alice, headers: headers)
      assert %{"result" => %{"resultType" => "complete", "content" => [_]}} = Jason.decode!(body)

      # A repeated header stays repeated.
      assert %{status: 400, body: body} =
               mcp(message, @alice, headers: Map.put(headers, "mcp-name", ["whoami", "whoami"]))

      assert %{
               "error" => %{
                 "code" => -32_020,
                 "message" => "Mcp-Name header must appear exactly once"
               }
             } =
               Jason.decode!(body)

      assert %{status: 400} = mcp(message, @alice, headers: Map.delete(headers, "mcp-method"))
    end

    test "subscriptions/listen returns its event stream as the body" do
      message = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "subscriptions/listen",
        "params" => %{"_meta" => @meta}
      }

      headers = %{"mcp-protocol-version" => @per_request, "mcp-method" => "subscriptions/listen"}

      assert %{status: 200, headers: %{"content-type" => "text/event-stream"}, body: body} =
               mcp(message, @alice, headers: headers)

      assert body =~ "notifications/subscriptions/acknowledged"
      assert [_, _] = Regex.scan(~r/^event: message$/m, body)
    end
  end

  describe "action authorization" do
    test "the endpoint's own policies apply to the action" do
      assert {:error, %Ash.Error.Forbidden{}} =
               run(PrivateEndpoint, :handle, %{"body" => %{"method" => "ping", "id" => 1}}, nil)

      assert {:ok, %{status: 200}} =
               run(
                 PrivateEndpoint,
                 :handle,
                 %{"body" => %{"method" => "ping", "id" => 1}},
                 @alice
               )
    end

    test "request keys may be atoms, and headers may be absent" do
      assert {:ok, %{status: 200, body: body}} =
               run(Endpoint, :mcp, %{body: %{"method" => "ping", "id" => 2}, headers: nil}, nil)

      assert Jason.decode!(body) == %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}
    end
  end

  describe "the in-memory conn" do
    test "answers the adapter callbacks the server does not use" do
      assert Conn.read_req_body("", []) == {:ok, "", ""}
      assert Conn.inform("", 103, []) == {:error, :not_supported}
      assert Conn.upgrade("", :websocket, []) == {:error, :not_supported}
      assert Conn.push("", "/", []) == {:error, :not_supported}
      assert %{address: {127, 0, 0, 1}} = Conn.get_peer_data("")
      assert %{address: {127, 0, 0, 1}} = Conn.get_sock_data("")
      assert Conn.get_ssl_data("") == nil
      assert Conn.get_http_protocol("") == :"HTTP/1.1"
      assert_raise ArgumentError, fn -> Conn.send_file("", 200, [], "x", 0, :all) end
    end

    test "sends nothing to the caller's mailbox" do
      mcp(%{"method" => "ping", "id" => 1}, nil)
      refute_received _any
    end
  end

  defp run(resource, action, request, actor) do
    resource
    |> Ash.ActionInput.for_action(action, %{request: request}, actor: actor)
    |> Ash.run_action()
  end

  defp mcp(body, actor, opts \\ []) do
    resource = Keyword.get(opts, :resource, Endpoint)

    request =
      %{"body" => body, "headers" => Keyword.get(opts, :headers, %{})}
      |> then(&if(opts[:server_url], do: Map.put(&1, "server_url", opts[:server_url]), else: &1))

    {:ok, response} = run(resource, Info.mcp_action_name(resource), request, actor)
    response
  end

  defp rpc(method, params, actor, opts \\ []) do
    %{status: 200, body: body} =
      mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}, actor, opts)

    Jason.decode!(body)
  end

  defp call(name, arguments, actor) do
    %{"result" => result} =
      rpc("tools/call", %{"name" => name, "arguments" => arguments}, actor)

    result
  end

  defp tool_names(actor) do
    %{"result" => %{"tools" => tools}} = rpc("tools/list", %{}, actor)
    tools |> Enum.map(& &1["name"]) |> Enum.sort()
  end
end
