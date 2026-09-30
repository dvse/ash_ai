# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Blended.DslTest do
  @moduledoc """
  BLENDED-001 (`expose`/`interface`), BLENDED-002 (the verifier), BLENDED-004
  (`refine?`/`action_parameters` agreement), BLENDED-008 (`delivery_hints`) and the DSL
  options of BLENDED-003/005/006/007/009/010/012.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshAi.Test.Blended
  alias AshAi.Test.Blended.{Author, Comment, Post}
  alias AshAi.Verifiers.VerifyExposures

  defmodule Widget do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, create: [:name]]
    end
  end

  describe "BLENDED-001 expose/interface" do
    test "entities are introspectable and separated from tools" do
      assert [%AshAi.Expose{resource: Post} = post, %AshAi.Expose{resource: Author}] =
               AshAi.Info.exposes(Blended)

      assert is_function(post.delivery_hints, 1)

      assert Enum.map(post.interfaces, & &1.name) == [
               :publish_post,
               :post_by_title,
               :hidden_posts,
               :await
             ]

      assert Enum.all?(AshAi.Info.action_tools(Blended), &match?(%AshAi.Tool{}, &1))
      assert length(AshAi.Info.tools(Blended)) == length(AshAi.Info.action_tools(Blended)) + 2
    end

    test "each interface becomes a tool named after it, calling the action behind the define" do
      tools = Map.new(AshAi.Info.interface_tools(Blended), &{&1.name, &1})

      assert %AshAi.Tool{
               resource: Post,
               action: :publish,
               interface: :publish_post,
               description: "Publishes a post.",
               annotations: [read_only?: true],
               refine?: true,
               output_schema?: true
             } = tools.publish_post

      assert tools.publish_post.example =~ "Final"
      assert tools.await.action == :wait_for
      assert tools.post_by_title.refine? == false
    end

    test "interfaces over non-public actions are skipped" do
      names = Enum.map(AshAi.Info.interface_tools(Blended), & &1.name)

      refute :hidden_posts in names

      assert Enum.sort(names) ==
               Enum.sort([
                 :publish_post,
                 :post_by_title,
                 :await,
                 :author_by_id,
                 :author_by_name,
                 :rename_author,
                 :drop_author_by_name
               ])
    end

    test "a define's get_by / get_by_identity addresses records" do
      tools = Map.new(AshAi.Info.interface_tools(Blended), &{&1.name, &1})

      assert tools.post_by_title.get_by == [:title]
      assert tools.author_by_id.get_by == [:id]
      assert tools.author_by_name.get_by == [:name]
      assert tools.rename_author.identity == :unique_name
      assert tools.rename_author.get_by == nil
      assert tools.drop_author_by_name.identity == nil
      assert tools.drop_author_by_name.get_by == nil
      assert tools.publish_post.get_by == nil
    end

    test "interface tools are exposed with their domain, action struct and delivery hints" do
      tools = Map.new(AshAi.exposed_tools(actions: [{Post, :*}, {Author, :*}]), &{&1.name, &1})

      assert %Ash.Resource.Actions.Update{name: :publish} = tools.publish_post.action
      assert tools.publish_post.domain == Blended
      assert tools.publish_post.delivery_hints == (&Blended.post_delivery_hints/1)
      assert tools.create_post.delivery_hints == (&Blended.post_delivery_hints/1)
      assert tools.author_by_id.delivery_hints == nil
    end

    test "delivery_hints collapses to its callback" do
      domain =
        domain(
          quote do
            tools do
              expose AshAi.Blended.DslTest.Widget do
                delivery_hints(fn _context -> nil end)
                interface(:list_widgets)
              end
            end

            resources do
              resource AshAi.Blended.DslTest.Widget do
                define(:list_widgets, action: :read)
              end
            end
          end
        )

      assert [%AshAi.Expose{delivery_hints: callback}] = AshAi.Info.exposes(domain)
      assert is_function(callback, 1)
    end

    test "expose is rejected inside a resource" do
      module = Module.concat(__MODULE__, :"ResourceExpose#{System.unique_integer([:positive])}")

      assert_raise Spark.Error.DslError, ~r/`expose` is only allowed in a domain-level/, fn ->
        Module.create(
          module,
          quote do
            use Ash.Resource,
              domain: AshAi.Test.Blended,
              extensions: [AshAi],
              data_layer: Ash.DataLayer.Ets,
              validate_domain_inclusion?: false

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            tools do
              expose AshAi.Test.Blended.Comment do
                interface(:anything)
              end
            end
          end,
          Macro.Env.location(__ENV__)
        )
      end
    end
  end

  describe "BLENDED-002 VerifyExposures" do
    test "a valid domain verifies" do
      assert :ok = VerifyExposures.verify(Blended.spark_dsl_config())
    end

    test "the exposed resource must be in the domain resources block" do
      domain =
        domain(
          quote do
            tools do
              expose AshAi.Blended.DslTest.Widget do
                interface(:list_widgets)
              end
            end
          end
        )

      assert {:error, %Spark.Error.DslError{message: message, path: path}} =
               VerifyExposures.verify(domain.spark_dsl_config())

      assert message =~
               "expose AshAi.Blended.DslTest.Widget must reference a resource registered in the domain resources block"

      assert path == [:tools, :expose, Widget]
    end

    test "each interface must match a define" do
      domain =
        domain(
          quote do
            tools do
              expose AshAi.Blended.DslTest.Widget do
                interface(:list_widgets)
                interface(:missing)
              end
            end

            resources do
              resource AshAi.Blended.DslTest.Widget do
                define(:list_widgets, action: :read)
              end
            end
          end
        )

      assert {:error, %Spark.Error.DslError{message: message}} =
               VerifyExposures.verify(domain.spark_dsl_config())

      assert message =~
               "expose AshAi.Blended.DslTest.Widget declares interface :missing, but AshAi.Blended.DslTest.Widget has no matching define :missing"
    end

    test "interface names must not collide with tools or other interfaces" do
      domain =
        domain(
          quote do
            tools do
              tool(:list_widgets, AshAi.Blended.DslTest.Widget, :read)

              expose AshAi.Blended.DslTest.Widget do
                interface(:list_widgets)
                interface(:create_widget)
                interface(:create_widget)
              end
            end

            resources do
              resource AshAi.Blended.DslTest.Widget do
                define(:list_widgets, action: :read)
                define(:create_widget, action: :create)
              end
            end
          end
        )

      assert {:error, %Spark.Error.DslError{message: message}} =
               VerifyExposures.verify(domain.spark_dsl_config())

      assert message =~ "Duplicate tool names found in"
      assert message =~ ": create_widget, list_widgets."
    end

    test "duplicate `tool` entries alone keep upstream's runtime error" do
      domain =
        domain(
          quote do
            tools do
              tool(:list_widgets, AshAi.Blended.DslTest.Widget, :read)
              tool(:list_widgets, AshAi.Blended.DslTest.Widget, :read)
            end

            resources do
              resource(AshAi.Blended.DslTest.Widget)
            end
          end
        )

      assert :ok = VerifyExposures.verify(domain.spark_dsl_config())
    end

    test "verifier errors are reported when the domain compiles" do
      output =
        capture_io(:stderr, fn ->
          domain(
            quote do
              tools do
                expose AshAi.Blended.DslTest.Widget do
                  interface(:nope)
                end
              end
            end
          )
        end)

      assert output =~ "must reference a resource registered in the domain resources block"
    end
  end

  describe "BLENDED-004 refine?" do
    test "refine?: false with a non-empty action_parameters is a compile error" do
      assert_raise Spark.Error.DslError,
                   ~r/sets `refine\?: false`.*non-empty `action_parameters`/s,
                   fn ->
                     domain(
                       quote do
                         tools do
                           tool(:list_widgets, AshAi.Blended.DslTest.Widget, :read,
                             refine?: false,
                             action_parameters: [:filter]
                           )
                         end
                       end
                     )
                   end
    end

    test "refine?: false agrees with action_parameters: []" do
      domain =
        domain(
          quote do
            tools do
              tool(:list_widgets, AshAi.Blended.DslTest.Widget, :read,
                refine?: false,
                action_parameters: []
              )
            end
          end
        )

      assert [%AshAi.Tool{refine?: false, action_parameters: []}] =
               AshAi.Info.action_tools(domain)
    end
  end

  describe "tool option defaults" do
    test "BLENDED options default like upstream behaviour" do
      tool = Enum.find(AshAi.Info.action_tools(Blended), &(&1.name == :list_comments))

      assert %AshAi.Tool{
               resource: Comment,
               example: nil,
               blocking?: nil,
               continuation_target?: false,
               hints: nil,
               annotations: [],
               output_schema?: true
             } = tool
    end
  end

  defp domain(body) do
    module = Module.concat(__MODULE__, :"Domain#{System.unique_integer([:positive])}")

    capture_io(:stderr, fn ->
      Module.create(
        module,
        quote do
          use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false
          unquote(body)
        end,
        Macro.Env.location(__ENV__)
      )
    end)

    module
  end
end
