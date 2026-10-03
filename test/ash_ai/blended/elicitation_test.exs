# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.ElicitationTest do
  @moduledoc """
  BLENDED-023: `elicit_missing?` — missing input of a tool call is asked of the user as a form
  (MCP 2026-07-28 `input_required` results; a server-to-client `elicitation/create` request on
  initialize-based connections), validated before the action runs, and the action runs once.
  """
  use ExUnit.Case, async: false

  alias AshAi.Test.Elicitation.{Endpoint, Order}

  @alice %{name: "alice"}
  @standard %{"elicitation" => %{}}
  @openai %{"extensions" => %{"openai/elicitation" => %{"form" => %{}}}}
  @tools [
    :place_order,
    :place_order_plain,
    :place_labelled,
    :attach_spec,
    :reprice_order,
    :orders_by_part,
    :quote_order
  ]
  @server_info %{
    "io.modelcontextprotocol/serverInfo" => %{"name" => "MCP Server", "version" => "1.1.1"}
  }

  setup do
    for order <- Ash.read!(Order, authorize?: false), do: Ash.destroy!(order, authorize?: false)
    :ok
  end

  describe "opt-in" do
    test "a tool without the option answers missing input as upstream does" do
      upstream = %{
        "isError" => true,
        "content" => [%{"type" => "text", "text" => "part: is required\nquantity: is required"}]
      }

      assert call("place_order_plain", %{}, @standard) ==
               Map.merge(upstream, %{"resultType" => "complete", "_meta" => @server_info})

      session = initialize(@standard)
      response = legacy_call(session, "place_order_plain", %{})
      assert response.content_type == ["application/json"]
      assert response.body == %{"jsonrpc" => "2.0", "id" => 1, "result" => upstream}
      assert rows() == 0
    end

    test "tools/list is the same with and without the option" do
      %{"result" => %{"tools" => tools}} = rpc("tools/list", %{})
      elicited = Enum.find(tools, &(&1["name"] == "place_order"))
      plain = Enum.find(tools, &(&1["name"] == "place_order_plain"))

      assert Map.drop(elicited, ["name", "title"]) == Map.drop(plain, ["name", "title"])
      refute Map.has_key?(elicited, "_meta")
    end

    test "a client that does not declare form elicitation gets the call's errors" do
      for capabilities <- [%{}, %{"elicitation" => %{"url" => %{}}}, %{"elicitation" => true}] do
        assert %{"isError" => true, "resultType" => "complete", "content" => [%{"text" => text}]} =
                 call("place_order", %{}, capabilities)

        assert text == "part: is required\nquantity: is required"
      end

      assert rows() == 0
    end
  end

  describe "2026-07-28 (input_required)" do
    test "missing input is asked before the action runs" do
      assert call("place_order", %{}, @standard) == %{
               "resultType" => "input_required",
               "_meta" => @server_info,
               "inputRequests" => %{
                 "missing_input" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "mode" => "form",
                     "message" =>
                       "place_order needs more input.\nquantity: is required\npart: is required",
                     "requestedSchema" => %{
                       "type" => "object",
                       "properties" => %{
                         "part" => %{
                           "type" => "string",
                           "title" => "Part",
                           "description" => "The part to order."
                         },
                         "quantity" => %{
                           "type" => "integer",
                           "title" => "Quantity",
                           "minimum" => 1,
                           "maximum" => 10
                         }
                       },
                       "required" => ["quantity", "part"]
                     }
                   }
                 }
               }
             }

      assert rows() == 0
    end

    test "a call with the answers runs the action once" do
      result =
        call("place_order", %{"input" => %{"note" => "rush"}}, @standard, %{
          "inputResponses" => accept(%{"part" => "bolt", "quantity" => 2})
        })

      assert %{"isError" => false, "resultType" => "complete", "structuredContent" => order} =
               result

      assert %{"part" => "bolt", "quantity" => 2, "note" => "rush"} = order
      assert [%{part: "bolt", quantity: 2}] = Ash.read!(Order, authorize?: false)
    end

    test "an answer that is still invalid is asked again with its error, keeping the others" do
      result =
        call("place_order", %{}, @standard, %{
          "inputResponses" => accept(%{"part" => "bolt", "quantity" => 20})
        })

      assert %{"resultType" => "input_required", "inputRequests" => %{"missing_input" => request}} =
               result

      assert request["params"]["message"] ==
               "place_order needs more input.\nquantity: must be less than or equal to 10"

      assert request["params"]["requestedSchema"] == %{
               "type" => "object",
               "properties" => %{
                 "quantity" => %{
                   "type" => "integer",
                   "title" => "Quantity",
                   "minimum" => 1,
                   "maximum" => 10,
                   "default" => 20
                 },
                 "part" => %{
                   "type" => "string",
                   "title" => "Part",
                   "description" => "The part to order.",
                   "default" => "bolt"
                 }
               },
               "required" => ["quantity", "part"]
             }

      assert rows() == 0

      assert %{"isError" => false} =
               call("place_order", %{}, @standard, %{
                 "inputResponses" => accept(%{"part" => "bolt", "quantity" => 3})
               })

      assert rows() == 1
    end

    test "a declined or cancelled answer does not run the action" do
      for {action, text} <- [
            {"decline", "input declined: tool place_order did not run"},
            {"cancel", "input cancelled: tool place_order did not run"}
          ] do
        assert call("place_order", %{}, @standard, %{
                 "inputResponses" => %{"missing_input" => %{"action" => action}}
               }) == %{
                 "isError" => true,
                 "content" => [%{"type" => "text", "text" => text}],
                 "resultType" => "complete",
                 "_meta" => @server_info
               }
      end

      assert rows() == 0
    end

    test "other errors stay errors" do
      # A validation's error, beside the missing input
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               call("place_order", %{"input" => %{"note" => "forbidden"}}, @standard)

      assert text =~ "note:"

      # An input the tool does not declare
      assert %{"isError" => true, "content" => [%{"text" => "Unknown arguments provided: " <> _}]} =
               call("place_order", %{"input" => %{"colour" => "red"}}, @standard)

      # A missing input that has no form field (a map)
      assert %{
               "isError" => true,
               "content" => [%{"text" => "spec: is required\npart: is required"}]
             } =
               call("attach_spec", %{}, @standard)

      # `input` that is not an object
      assert %{"isError" => true} = call("place_order", %{"input" => "part=bolt"}, @standard)

      assert rows() == 0
    end

    test "a create's required attribute is asked as a required field" do
      assert %{"inputRequests" => %{"missing_input" => %{"params" => params}}} =
               call("place_labelled", %{}, @standard)

      assert params["requestedSchema"]["required"] == ["label", "part"]

      assert params["requestedSchema"]["properties"]["label"] == %{
               "type" => "string",
               "title" => "Label",
               "description" => "A label for the order."
             }

      assert %{"isError" => false} =
               call("place_labelled", %{}, @standard, %{
                 "inputResponses" => accept(%{"label" => "L", "part" => "nut"})
               })

      assert rows() == 1
    end

    test "update, read and generic actions are validated the same way" do
      order = Ash.create!(Order, %{part: "bolt", quantity: 1}, action: :place, actor: @alice)

      assert %{
               "inputRequests" => %{
                 "missing_input" => %{"params" => %{"requestedSchema" => schema}}
               }
             } =
               call("reprice_order", %{"id" => order.id}, @standard)

      assert schema["required"] == ["quantity"]

      assert %{"isError" => false, "structuredContent" => %{"quantity" => 4}} =
               call("reprice_order", %{"id" => order.id}, @standard, %{
                 "inputResponses" => accept(%{"quantity" => 4})
               })

      assert %{"inputRequests" => %{"missing_input" => _}} =
               call("orders_by_part", %{}, @standard)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               call("orders_by_part", %{}, @standard, %{
                 "inputResponses" => accept(%{"part" => "bolt"})
               })

      assert [%{"part" => "bolt"}] = Jason.decode!(text)

      assert %{"inputRequests" => %{"missing_input" => %{"params" => params}}} =
               call("quote_order", %{"input" => %{"quantity" => 9}}, @standard)

      assert params["message"] ==
               "quote_order needs more input.\npart: is required\nquantity: must be less than or equal to 5"

      assert %{"isError" => false, "content" => [%{"text" => ~s("2 x nut")}]} =
               call("quote_order", %{"input" => %{"quantity" => 9}}, @standard, %{
                 "inputResponses" => accept(%{"part" => "nut", "quantity" => 2})
               })
    end

    test "a client advertising openai/elicitation is asked with openai/elicitation/create" do
      assert %{"inputRequests" => %{"missing_input" => %{"method" => method}}} =
               call("place_order", %{}, @openai)

      assert method == "openai/elicitation/create"

      # Both declared: the OpenAI form wins
      assert %{
               "inputRequests" => %{"missing_input" => %{"method" => "openai/elicitation/create"}}
             } =
               call("place_order", %{}, Map.merge(@standard, @openai))
    end
  end

  describe "requestedSchema" do
    @invalid %{
      "part" => "bolt",
      "quantity" => 1,
      "code" => "ab",
      "size" => "medium",
      "finish" => "shiny",
      "express" => "maybe",
      "due" => "someday",
      "weight" => 100,
      "colors" => ["pink"]
    }

    test "each constraint kind becomes its form keyword" do
      assert %{"inputRequests" => %{"missing_input" => %{"params" => params}}} =
               call("place_order", %{"input" => @invalid}, @standard)

      assert params["requestedSchema"] == %{
               "type" => "object",
               "properties" => %{
                 "code" => %{
                   "type" => "string",
                   "title" => "Code",
                   "minLength" => 3,
                   "maxLength" => 3
                 },
                 "size" => %{"type" => "string", "title" => "Size", "enum" => ["small", "large"]},
                 "finish" => %{
                   "type" => "string",
                   "title" => "Finish",
                   "enum" => ["matte", "gloss"]
                 },
                 "express" => %{"type" => "boolean", "title" => "Express"},
                 "due" => %{"type" => "string", "title" => "Due", "format" => "date"},
                 "weight" => %{
                   "type" => "number",
                   "title" => "Weight",
                   "minimum" => 0.5,
                   "maximum" => 99.5
                 },
                 "colors" => %{
                   "type" => "array",
                   "title" => "Colors",
                   "items" => %{"type" => "string", "enum" => ["red", "blue", "green"]},
                   "minItems" => 1,
                   "maxItems" => 2
                 }
               }
             }
    end

    test "the OpenAI form also carries a string's pattern" do
      assert %{"inputRequests" => %{"missing_input" => %{"params" => params}}} =
               call("place_order", %{"input" => @invalid}, @openai)

      assert params["requestedSchema"]["properties"]["code"] == %{
               "type" => "string",
               "title" => "Code",
               "minLength" => 3,
               "maxLength" => 3,
               "pattern" => "^[A-Z]{3}$"
             }
    end
  end

  describe "initialize-based connections (elicitation/create)" do
    test "the call streams the request, takes the POSTed answer and runs once" do
      session = initialize(@standard)
      task = Task.async(fn -> legacy_call(session, "place_order", %{}) end)

      [request_id] = pending(session)
      assert "ash_ai/elicitation/" <> _ = request_id

      assert answer(session, request_id, %{
               "action" => "accept",
               "content" => %{"part" => "bolt", "quantity" => 2}
             }) ==
               202

      response = Task.await(task)
      assert response.status == 200
      assert response.content_type == ["text/event-stream"]

      assert [request, result] = events(response.body)

      assert request == %{
               "jsonrpc" => "2.0",
               "id" => request_id,
               "method" => "elicitation/create",
               "params" =>
                 call("place_order", %{}, @standard)["inputRequests"]["missing_input"]["params"]
             }

      assert %{"id" => 1, "result" => %{"isError" => false, "structuredContent" => order}} =
               result

      assert %{"part" => "bolt", "quantity" => 2} = order
      assert rows() == 1
      assert pending(session, 0) == []
    end

    test "an invalid answer is asked again on the same stream" do
      session = initialize(@openai)
      task = Task.async(fn -> legacy_call(session, "place_order", %{}) end)

      [first] = pending(session)
      answer(session, first, accept(%{"part" => "bolt", "quantity" => 20})["missing_input"])
      [second] = wait_for(fn -> Enum.reject(pending(session, 0), &(&1 == first)) end)
      answer(session, second, accept(%{"part" => "bolt", "quantity" => 5})["missing_input"])

      assert [ask, again, %{"result" => %{"isError" => false}}] = events(Task.await(task).body)
      assert ask["method"] == "openai/elicitation/create"
      assert again["id"] == second
      assert again["params"]["requestedSchema"]["properties"]["quantity"]["default"] == 20
      assert rows() == 1
    end

    test "a declined answer, or none in time, does not run the action" do
      session = initialize(@standard)
      task = Task.async(fn -> legacy_call(session, "place_order", %{}) end)
      [request_id] = pending(session)
      answer(session, request_id, %{"action" => "decline"})

      assert [_request, %{"result" => result}] = events(Task.await(task).body)

      assert result == %{
               "isError" => true,
               "content" => [
                 %{"type" => "text", "text" => "input declined: tool place_order did not run"}
               ]
             }

      response = legacy_call(session, "place_order", %{}, elicitation_timeout_ms: 20)

      assert [_request, %{"result" => %{"content" => [%{"text" => text}]}}] =
               events(response.body)

      assert text == "input cancelled: tool place_order did not run"
      assert rows() == 0
    end

    test "an error answer runs the call as it would without the option" do
      session = initialize(@standard)
      task = Task.async(fn -> legacy_call(session, "place_order", %{}) end)
      [request_id] = pending(session)

      assert post(session, %{
               "jsonrpc" => "2.0",
               "id" => request_id,
               "error" => %{"code" => -32_601, "message" => "Method not found"}
             }).status == 202

      assert [_request, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}] =
               events(Task.await(task).body)

      assert text == "part: is required\nquantity: is required"
    end

    test "a session whose client cannot be asked, or that ended, gets the call's errors" do
      for capabilities <- [%{}, %{"elicitation" => %{"url" => %{}}}] do
        session = initialize(capabilities)
        response = legacy_call(session, "place_order", %{})
        assert response.content_type == ["application/json"]
        assert %{"result" => %{"isError" => true}} = response.body
      end

      session = initialize(@standard)

      assert Plug.Test.conn(:delete, "/")
             |> Plug.Conn.put_req_header("mcp-session-id", session)
             |> AshAi.Mcp.Router.call(router_opts([]))
             |> Map.fetch!(:status) == 200

      assert %{"result" => %{"isError" => true}} = legacy_call(session, "place_order", %{}).body
    end

    test "an answer nobody waits on is handled as upstream handles it" do
      session = initialize(@standard)

      response =
        post(session, %{"jsonrpc" => "2.0", "id" => "ash_ai/elicitation/none", "result" => %{}})

      assert response.status == 200
      assert %{"error" => %{"code" => -32_600}} = Jason.decode!(response.resp_body)
    end

    test "the in-memory conn of AshAi.McpActions never streams" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => @standard}
      }

      {:ok, %{headers: headers}} = mcp_action(initialize, %{})
      session = headers["mcp-session-id"]

      {:ok, %{status: 200, headers: headers, body: body}} =
        mcp_action(
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => "place_order", "arguments" => %{}}
          },
          %{"mcp-session-id" => session}
        )

      assert headers["content-type"] == "application/json"
      assert %{"result" => %{"isError" => true}} = Jason.decode!(body)
    end
  end

  defp accept(content), do: %{"missing_input" => %{"action" => "accept", "content" => content}}

  defp rows, do: Order |> Ash.read!(authorize?: false) |> length()

  defp call(name, arguments, capabilities, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => capabilities
    }

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => Map.merge(%{"name" => name, "arguments" => arguments, "_meta" => meta}, params)
    }

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
    |> Plug.Conn.put_req_header("mcp-method", "tools/call")
    |> Plug.Conn.put_req_header("mcp-name", name)
    |> Ash.PlugHelpers.set_actor(@alice)
    |> AshAi.Mcp.Router.call(router_opts([]))
    |> then(&Jason.decode!(&1.resp_body)["result"])
  end

  defp rpc(method, params) do
    Plug.Test.conn(:post, "/", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
    |> Ash.PlugHelpers.set_actor(@alice)
    |> AshAi.Mcp.Router.call(router_opts([]))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp initialize(capabilities) do
    conn =
      post(nil, %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => capabilities}
      })

    [session] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    session
  end

  defp legacy_call(session, name, arguments, opts \\ []) do
    conn =
      post(
        session,
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => arguments}
        },
        opts
      )

    content_type = Plug.Conn.get_resp_header(conn, "content-type")

    body =
      if content_type == ["text/event-stream"],
        do: conn.resp_body,
        else: Jason.decode!(conn.resp_body)

    %{status: conn.status, content_type: content_type, body: body}
  end

  defp answer(session, request_id, result) do
    post(session, %{"jsonrpc" => "2.0", "id" => request_id, "result" => result}).status
  end

  defp post(session, body, opts \\ []) do
    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
    |> then(&if(session, do: Plug.Conn.put_req_header(&1, "mcp-session-id", session), else: &1))
    |> Ash.PlugHelpers.set_actor(@alice)
    |> AshAi.Mcp.Router.call(router_opts(opts))
  end

  defp router_opts(opts) do
    AshAi.Mcp.Router.init(
      Keyword.merge([otp_app: :ash_ai, tools: @tools, actions: [{Order, :*}]], opts)
    )
  end

  defp mcp_action(body, headers) do
    Endpoint
    |> Ash.ActionInput.for_action(:mcp, %{request: %{"body" => body, "headers" => headers}},
      actor: @alice
    )
    |> Ash.run_action()
  end

  # The request ids the session's calls wait on, once at least `count` are.
  defp pending(session, count \\ 1) do
    wait_for(
      fn ->
        ids = AshAi.Mcp.Elicitations.pending(session)
        if length(ids) >= count, do: ids, else: []
      end,
      count == 0
    )
  end

  defp wait_for(fun, accept_empty? \\ false, attempts \\ 200) do
    case fun.() do
      [] when attempts > 0 and not accept_empty? ->
        Process.sleep(10)
        wait_for(fun, accept_empty?, attempts - 1)

      result ->
        result
    end
  end

  defp events(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&(&1 |> String.trim_leading("data: ") |> Jason.decode!()))
  end
end
