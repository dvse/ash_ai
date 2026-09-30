# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.OutputSchemaTest do
  @moduledoc """
  BLENDED-010: every tool in the test support domains (`AshAi.Test.Music`,
  `AshAi.Test.Blended`) is called over MCP for every result shape it can produce, and each
  result is validated with JSON Schema (`JsonXema`, already in the dependency tree through
  `ash_json_api`):

    * the JSON text content against `AshAi.Tool.Schema.result_for_tool/1`;
    * `structuredContent` against the advertised `outputSchema`, which must be present
      exactly when the result schema is an object;
    * `structuredContent` equals the decoded text content.
  """
  use AshAi.RepoCase, async: false
  import Plug.Test

  alias AshAi.Mcp.Router
  alias AshAi.Test.Blended.{Author, Comment, Post}
  alias AshAi.Test.Music

  @music_opts [
    otp_app: :ash_ai,
    actions: [
      {Music.ArtistAfterAction, :*},
      {Music.ArtistOban, :*},
      {Music.ArtistManual, :*}
    ]
  ]

  # A non-admin actor, so the `secret` field is forbidden by its field policy.
  @blended_opts [
    actions: [{Post, :*}, {Author, :*}, {Comment, :*}],
    actor: %{admin: false}
  ]

  describe "Music domain" do
    test "every tool's results match its output schema" do
      artist = Music.create_artist_after_action!(%{name: "Artist", bio: "Bio"})
      manual = Music.create_artist_manual!(%{name: "Manual", bio: "Bio"})
      Music.create_artist_oban!(%{name: "Oban", bio: "Bio"})

      calls = %{
        "list_artists" => read_calls(),
        "list_artists_oban" => read_calls(),
        "list_artists_with_meta" => [%{}],
        "list_artists_with_ui" => [%{}],
        "create_artist_after" => [%{"input" => %{"name" => "New", "bio" => "b"}}],
        "update_artist_after" => [%{"id" => artist.id, "input" => %{"bio" => "c"}}],
        "create_artist_manual" => [%{"input" => %{"name" => "New2"}}],
        "update_artist_manual" => [%{"id" => manual.id, "input" => %{"bio" => "c"}}]
      }

      sweep(@music_opts, calls)
    end
  end

  describe "Blended domain" do
    test "every tool's results match its output schema, for every result shape" do
      author = Ash.create!(Author, %{name: "Ann"}, domain: AshAi.Test.Blended)
      doomed = Ash.create!(Author, %{name: "Doomed"}, domain: AshAi.Test.Blended)

      [first, second, _third] =
        for n <- 1..3 do
          Ash.create!(
            Post,
            %{
              title: "Post #{n}",
              body: if(n == 1, do: nil, else: "body"),
              score: Decimal.new("#{n}.25"),
              mood: :happy,
              secret: "s#{n}",
              internal: "i#{n}",
              address: %{city: "Brisbane"},
              tags: ["x"],
              author_id: author.id
            },
            authorize?: false
          )
        end

      Ash.create!(Comment, %{body: "c", post_id: first.id}, domain: AshAi.Test.Blended)
      victim = Ash.create!(Post, %{title: "Victim"}, authorize?: false)

      keyset = keyset_cursor("keyset_posts")

      calls = %{
        "list_posts" =>
          read_calls() ++
            [
              %{"result_type" => %{"aggregate" => "max", "field" => "title"}},
              %{"result_type" => %{"aggregate" => "avg", "field" => "score"}},
              %{"result_type" => %{"aggregate" => "min", "field" => "mood"}},
              %{"filter" => %{"field" => "title", "operator" => "eq", "value" => "none"}}
            ],
        "plain_posts" => [%{}],
        "select_posts" => [%{}],
        "count_posts" => [%{}, %{"result_type" => "count"}],
        "filter_posts" => [%{"result_type" => "exists"}, %{}],
        "sort_posts" => [%{"sort" => [%{"field" => "title", "direction" => "desc"}]}],
        "none_posts" => [%{}],
        "offset_posts" => [%{}, %{"offset" => 2}],
        "offset_posts_all" => [%{"result_type" => "count"}, %{"offset" => 1}],
        "keyset_posts" => [%{}, %{"after" => keyset}],
        "both_posts" => [%{}, %{"offset" => 1}],
        "get_post" => [%{"id" => first.id}],
        "dynamic_posts" => [%{}],
        "search_posts" => [%{}],
        "await_posts" => [%{}],
        "resource_list_posts" => [%{}],
        "create_post" => [%{"input" => %{"title" => "Fresh", "score" => "1.5", "mood" => "sad"}}],
        "update_post" => [%{"id" => second.id, "input" => %{"body" => "changed"}}],
        "destroy_post" => [%{"id" => victim.id}],
        "create_author" => [%{"input" => %{"name" => "Bob"}}],
        "list_comments" => [%{}],
        "stats" => [%{}],
        "stats_no_schema" => [%{}],
        "stats_hinted" => [%{}],
        "stats_module_hint" => [%{}],
        "summary" => [%{}],
        "loose_struct" => [%{}],
        "post_record" => [%{}],
        "address" => [%{}],
        "pick" =>
          for(
            kind <- ~w(record text number loose loose_map free),
            do: %{"input" => %{"kind" => kind}}
          ),
        "keywords" => [%{}],
        "pair" => [%{}],
        "price" => [%{}],
        "mood_now" => [%{}],
        "loose_map" => [%{}],
        "scalar" => [%{}],
        "numbers" => [%{}],
        "maybe" => [%{}],
        "nothing" => [%{}],
        "needs_input" => [%{"input" => %{"name" => "n"}}],
        "await_now" => [%{}],
        "wait_for" => [%{}],
        "await" => [%{}],
        "protected" => [{:error, %{}}],
        "protected_create" => [{:error, %{"input" => %{"title" => "no"}}}],
        "publish_post" => [%{"id" => first.id, "input" => %{"title" => "Published"}}],
        "post_by_title" => [%{"title" => "Post 3"}],
        "author_by_id" => [%{"id" => author.id}],
        "author_by_name" => [%{"name" => "Ann"}],
        "rename_author" => [%{"name" => "Ann", "input" => %{"name" => "Anne"}}],
        "drop_author_by_name" => [%{"id" => doomed.id}]
      }

      sweep(@blended_opts, calls)
    end
  end

  defp read_calls do
    [
      %{},
      %{"limit" => 1},
      %{"offset" => 1},
      %{"result_type" => "count"},
      %{"result_type" => "exists"},
      %{"result_type" => %{"aggregate" => "count", "field" => "id"}}
    ]
  end

  defp keyset_cursor(tool) do
    %{"structuredContent" => %{"end_keyset" => cursor}} =
      @blended_opts |> call(tool, %{"limit" => 1}) |> Map.fetch!("result")

    cursor
  end

  # Calls every advertised tool with each of its argument maps and validates the results.
  defp sweep(opts, calls) do
    listed = list_tools(opts)
    tools_by_name = Map.new(AshAi.exposed_tools(opts), &{to_string(&1.name), &1})

    # Every exposed tool is swept, and every swept tool is exposed.
    assert Enum.sort(Map.keys(calls)) == Enum.sort(Enum.map(listed, & &1["name"]))

    for %{"name" => name} = definition <- listed,
        call <- Map.fetch!(calls, name) do
      tool = Map.fetch!(tools_by_name, name)
      result_schema = AshAi.Tool.Schema.result_for_tool(tool)
      output_schema = definition["outputSchema"]

      # `outputSchema` is advertised exactly when every result is an object.
      assert output_schema == AshAi.Tool.Schema.output_for_tool(tool)

      if tool.output_schema? and match?(%{"type" => "object"}, result_schema) do
        assert output_schema == result_schema
      else
        assert output_schema == nil
      end

      case call do
        {:error, arguments} ->
          assert %{"isError" => true} = opts |> call(name, arguments) |> Map.fetch!("result")

        arguments ->
          result = opts |> call(name, arguments) |> Map.fetch!("result")
          assert result["isError"] == false, "#{name} #{inspect(arguments)}: #{inspect(result)}"
          [%{"type" => "text", "text" => text} | _hints] = result["content"]

          if result_schema do
            value = Jason.decode!(text)
            assert_valid(result_schema, value, name, arguments)

            if is_map(value) do
              assert result["structuredContent"] == value
            else
              refute Map.has_key?(result, "structuredContent")
            end
          else
            assert text == "success"
          end

          if output_schema do
            assert Map.has_key?(result, "structuredContent"),
                   "#{name} advertises an outputSchema but returned no structuredContent"

            assert_valid(output_schema, result["structuredContent"], name, arguments)
          end
      end
    end
  end

  defp assert_valid(schema, value, name, arguments) do
    case schema |> JsonXema.new() |> JsonXema.validate(value) do
      :ok ->
        :ok

      {:error, error} ->
        flunk("""
        #{name} #{inspect(arguments)} returned a value that does not match its schema:
        #{Exception.message(error)}

        value: #{inspect(value)}
        schema: #{inspect(schema)}
        """)
    end
  end

  defp list_tools(opts) do
    conn(:post, "/", %{"method" => "tools/list", "id" => "list"})
    |> Router.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
    |> get_in(["result", "tools"])
  end

  defp call(opts, name, arguments) do
    conn(:post, "/", %{
      "method" => "tools/call",
      "id" => "call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
    |> Router.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end
end
