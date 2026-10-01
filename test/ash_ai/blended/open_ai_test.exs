# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.OpenAiTest do
  @moduledoc """
  BLENDED-016 (`securitySchemes`), BLENDED-018 (`openai/fileParams`) and BLENDED-019 (initialize
  version negotiation): the OpenAI Apps SDK tool descriptor fields over MCP.
  """
  use ExUnit.Case, async: false

  alias AshAi.Test.OpenAi.Endpoint

  @file_object %{
    "type" => "object",
    "properties" => %{
      "download_url" => %{"type" => "string"},
      "file_id" => %{"type" => "string"},
      "mime_type" => %{"type" => "string"},
      "file_name" => %{"type" => "string"}
    },
    "required" => ["download_url", "file_id"],
    "additionalProperties" => false
  }

  @a %{"download_url" => "https://files.example/a", "file_id" => "file-a"}
  @b %{
    "download_url" => "https://files.example/b",
    "file_id" => "file-b",
    "mime_type" => "application/pdf",
    "file_name" => "b.pdf"
  }

  describe "BLENDED-019 initialize negotiation" do
    test "an unsupported requested version is answered with the latest supported one" do
      for requested <- ["2025-11-25", "1999-01-01", nil] do
        %{"result" => result} = rpc("initialize", %{"protocolVersion" => requested})
        assert result["protocolVersion"] == "2025-06-18"
      end
    end

    test "a supported requested version is echoed" do
      for requested <- ["2025-06-18", "2025-03-26"] do
        %{"result" => result} = rpc("initialize", %{"protocolVersion" => requested})
        assert result["protocolVersion"] == requested
      end
    end
  end

  describe "BLENDED-016 securitySchemes" do
    test "a tool's own schemes are emitted at the top level and mirrored in _meta" do
      tool = tool("attach_document")
      assert tool["securitySchemes"] == [%{"type" => "oauth2", "scopes" => ["mcp"]}]
      assert tool["_meta"]["securitySchemes"] == tool["securitySchemes"]
      assert tool["_meta"]["openai/toolInvocation/invoking"] == "Attaching…"

      assert tool("scan_file")["securitySchemes"] == [%{"type" => "noauth"}]
    end

    test "a tool without schemes inherits the server's default" do
      assert tool("ping")["securitySchemes"] == [%{"type" => "oauth2", "scopes" => ["mcp"]}]
      assert tool("ping")["_meta"] == %{"securitySchemes" => tool("ping")["securitySchemes"]}
    end

    test "without a tool or server setting nothing is emitted" do
      [tool] = tools_without_endpoint([:ping])
      refute Map.has_key?(tool, "securitySchemes")
      refute Map.has_key?(tool, "_meta")
    end

    test "the request's schemes replace the section's default" do
      %{"result" => %{"tools" => tools}} =
        rpc("tools/list", %{}, security_schemes: [%{"type" => "noauth"}])

      ping = Enum.find(tools, &(&1["name"] == "ping"))
      assert ping["securitySchemes"] == [%{"type" => "noauth"}]
      attach = Enum.find(tools, &(&1["name"] == "attach_document"))
      assert attach["securitySchemes"] == [%{"type" => "oauth2", "scopes" => ["mcp"]}]
    end

    test "an unknown scheme is refused" do
      assert_raise ArgumentError, ~r/a security scheme is/, fn ->
        tools_without_endpoint([:bad_scheme])
      end
    end

    test "tools/call results do not carry securitySchemes" do
      result = call("ping", %{})
      refute result["isError"]
      refute Map.has_key?(result, "securitySchemes")
      refute Map.has_key?(result["_meta"] || %{}, "securitySchemes")
    end
  end

  describe "BLENDED-018 fileParams schema" do
    test "file fields are top-level with the Apps SDK schema; the rest stays in input" do
      tool = tool("attach_document")
      schema = tool["inputSchema"]
      assert schema["properties"]["file"] == @file_object
      assert schema["properties"]["files"] == %{"type" => "array", "items" => @file_object}

      assert Map.keys(schema["properties"]["input"]["properties"]) |> Enum.sort() == [
               "id",
               "note"
             ]

      assert schema["properties"]["input"]["required"] == ["id"]
      assert schema["required"] == ["input"]
      assert tool["_meta"]["openai/fileParams"] == ["file", "files"]
    end

    test "a required file field is required at the top level and the empty envelope goes" do
      schema = tool("scan_file")["inputSchema"]
      assert schema["properties"] == %{"file" => @file_object}
      assert schema["required"] == ["file"]
      assert tool("scan_file")["_meta"]["openai/fileParams"] == ["file"]
    end

    test "a file field must be a public :map or {:array, :map} argument" do
      assert_raise ArgumentError, ~r/must be of type :map or \{:array, :map\}/, fn ->
        tools_without_endpoint([:wrong_files])
      end

      assert_raise ArgumentError, ~r/not a public argument/, fn ->
        tools_without_endpoint([:missing_files])
      end
    end
  end

  describe "BLENDED-018 fileParams calls" do
    test "file objects are put back into the action input" do
      result =
        call("attach_document", %{"input" => %{"id" => "d1"}, "file" => @a, "files" => [@a, @b]})

      refute result["isError"]
      assert result["structuredContent"]["file"] == @a
      assert result["structuredContent"]["files"] == [@a, @b]
      assert result["structuredContent"]["id"] == "d1"
    end

    test "absent optional file fields are absent" do
      result = call("attach_document", %{"input" => %{"id" => "d1"}})
      refute result["isError"]
      assert result["structuredContent"]["file"] == nil
      assert result["structuredContent"]["files"] == nil
    end

    test "a field that is not a file object is refused before the action runs" do
      cases = [
        {%{"input" => %{"id" => "d1"}, "file" => "/mnt/data/a.pdf"},
         "file must be a file object"},
        {%{"input" => %{"id" => "d1"}, "file" => Map.delete(@a, "file_id")},
         "file needs file_id"},
        {%{"input" => %{"id" => "d1"}, "file" => Map.put(@a, "size", 3)},
         ~s(file has unknown fields "size")},
        {%{"input" => %{"id" => "d1"}, "files" => [@a, 7]}, "files[1] must be a file object"},
        {%{"input" => %{"id" => "d1"}, "files" => []}, "files must list at least one file"},
        {%{"input" => %{"id" => "d1"}, "files" => @a}, "files must be an array of file objects"},
        {%{}, "file is required"}
      ]

      for {arguments, text} <- cases do
        name = if arguments == %{}, do: "scan_file", else: "attach_document"
        result = call(name, arguments)
        assert result["isError"], inspect(arguments)
        assert [%{"type" => "text", "text" => message}] = result["content"]
        assert message =~ text
      end
    end

    test "more than twenty files are refused" do
      result =
        call("attach_document", %{"input" => %{"id" => "d1"}, "files" => List.duplicate(@a, 21)})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "at most 20"
    end

    test "request files reach the tool's action context" do
      files = [%{"file_id" => "file-a", "base64" => "JVBERi0="}]

      %{"result" => result} =
        rpc(
          "tools/call",
          %{
            "name" => "attach_document",
            "arguments" => %{"input" => %{"id" => "d1"}, "file" => @a}
          },
          files: files
        )

      assert result["structuredContent"]["mcp_files"] == 1

      %{"result" => result} =
        rpc("tools/call", %{
          "name" => "attach_document",
          "arguments" => %{"input" => %{"id" => "d1"}}
        })

      assert result["structuredContent"]["mcp_files"] == nil
    end
  end

  defp tool(name) do
    %{"result" => %{"tools" => tools}} = rpc("tools/list", %{})
    Enum.find(tools, &(&1["name"] == name))
  end

  defp tools_without_endpoint(tools) do
    conn =
      Plug.Test.conn(:post, "/", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    opts =
      AshAi.Mcp.Router.init(
        otp_app: :ash_ai,
        actions: [{AshAi.Test.OpenAi.Document, :*}],
        tools: tools
      )

    # A raise inside the router reaches the caller wrapped by Plug; unwrap it.
    conn =
      try do
        AshAi.Mcp.Router.call(conn, opts)
      rescue
        error in Plug.Conn.WrapperError -> reraise error.reason, error.stack
      end

    Jason.decode!(conn.resp_body)["result"]["tools"]
  end

  defp call(name, arguments) do
    %{"result" => result} = rpc("tools/call", %{"name" => name, "arguments" => arguments})
    result
  end

  defp rpc(method, params, opts \\ []) do
    request =
      %{
        "body" => %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        "headers" => %{}
      }
      |> then(&if(opts[:files], do: Map.put(&1, "files", opts[:files]), else: &1))
      |> then(
        &if(opts[:security_schemes],
          do: Map.put(&1, "security_schemes", opts[:security_schemes]),
          else: &1
        )
      )

    {:ok, %{status: 200, body: body}} =
      Endpoint
      |> Ash.ActionInput.for_action(:mcp, %{request: request})
      |> Ash.run_action()

    Jason.decode!(body)
  end
end
