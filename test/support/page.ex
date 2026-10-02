# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-020 (see BLENDED.md): a minimal "UI framework" (a Spark extension that
# names an `AshAi.Page` adapter) and a counter page served as an MCP Apps view. The end-to-end
# proof with a real framework is ash_blueprint's Phoenix example (`AshBlueprint.Phoenix.McpPage`).

defmodule AshAi.Test.Page.Framework do
  @moduledoc false
  use Spark.Dsl.Extension, sections: []

  def mcp_page_adapter, do: AshAi.Test.Page.Adapter
end

defmodule AshAi.Test.Page.Item do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.Page, data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id, writable?: true, public?: true
    attribute :label, :string, public?: true
    attribute :done?, :boolean, default: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:id, :label]]

    update :toggle do
      require_atomic? false

      change fn changeset, _ ->
        Ash.Changeset.force_change_attribute(changeset, :done?, !changeset.data.done?)
      end
    end
  end
end

defmodule AshAi.Test.Page.CounterPage do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.Page,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshAi.Test.Page.Framework]

  ets do
    private? false
  end

  attributes do
    attribute :session_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :count, :integer, default: 0, public?: true
    attribute :last_by, :string, public?: true
  end

  identities do
    identity :session, [:session_id], pre_check_with: AshAi.Test.Page
  end

  actions do
    defaults [:read, :destroy]

    create :mount do
      accept [:session_id, :count]
      upsert? true
      upsert_identity :session
      upsert_fields []
    end

    update :increment do
      require_atomic? false
      argument :by, :integer, default: 1, public?: true

      change fn changeset, context ->
        case Ash.Changeset.get_argument(changeset, :by) do
          by when by < 0 ->
            Ash.Changeset.add_error(changeset, field: :by, message: "must not be negative")

          by ->
            changeset
            |> Ash.Changeset.force_change_attribute(:count, changeset.data.count + by)
            |> Ash.Changeset.force_change_attribute(:last_by, context.actor && context.actor.name)
        end
      end
    end
  end
end

defmodule AshAi.Test.Page.Adapter do
  @moduledoc false
  @behaviour AshAi.Page

  alias AshAi.Test.Page.{CounterPage, Item}

  @impl true
  def document(page, info),
    do:
      {:ok,
       "<!doctype html><title>#{info.title}</title><main data-page=\"#{inspect(page)}\"></main>"}

  @impl true
  def actions(CounterPage), do: [{CounterPage, :increment}, {Item, :toggle}]

  @impl true
  def session(_page, session_id),
    do: %{context: %{session_id: session_id}, inputs: %{session_id: session_id}}

  @impl true
  def mount(page, session_id, scope) do
    case do_mount(page, session_id, scope) do
      {:ok, _row} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp do_mount(page, session_id, scope) do
    page
    |> Ash.Changeset.for_create(:mount, %{session_id: session_id},
      actor: scope.actor,
      context: scope.context
    )
    |> Ash.create()
  end

  @impl true
  def render(page, session_id, scope) do
    with {:ok, row} <- do_mount(page, session_id, scope) do
      items = Ash.read!(Item)

      bindings =
        Map.new(items, fn item ->
          {"toggle-#{item.id}",
           %{
             resource: Item,
             action: :toggle,
             arguments: %{},
             event: %{},
             accept: [],
             bound_field: nil,
             target: {:row, %{id: item.id}}
           }}
        end)
        |> Map.put("increment", %{
          resource: CounterPage,
          action: :increment,
          arguments: %{"by" => 1},
          event: %{},
          accept: ["by"],
          bound_field: nil,
          target: :page
        })

      {:ok,
       %{
         "html" => "count=#{row.count} by=#{row.last_by} session=#{session_id}",
         "params" => scope.params,
         "errors" => scope.errors,
         "bindings" => bindings
       }}
    end
  end
end

defmodule AshAi.Test.Page.RunFramework do
  @moduledoc false
  use Spark.Dsl.Extension, sections: []

  def mcp_page_adapter, do: AshAi.Test.Page.RunAdapter
end

defmodule AshAi.Test.Page.GuardedPage do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.Page,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshAi.Test.Page.RunFramework]

  ets do
    private? false
  end

  attributes do
    attribute :session_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :count, :integer, default: 0, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :mount do
      accept [:session_id]
    end

    update :bump do
      accept [:count]
    end
  end
end

defmodule AshAi.Test.Page.RunAdapter do
  @moduledoc false
  # A framework whose page rows are reachable only through its own dispatch: it runs the page's
  # actions itself (`c:AshAi.Page.run/4`).
  @behaviour AshAi.Page

  alias AshAi.Test.Page.GuardedPage

  @impl true
  def document(_page, _info), do: {:ok, "<!doctype html><main>guarded</main>"}

  @impl true
  def actions(GuardedPage), do: [{GuardedPage, :bump}]

  @impl true
  def session(_page, _session_id), do: %{context: %{}, inputs: %{}}

  @impl true
  def run(GuardedPage, session_id, %{action: :bump, arguments: arguments}, _scope) do
    by = get_in(arguments, ["input", "count"]) || 1

    if by < 0 do
      {:error, "the page refused the bump"}
    else
      row = row(session_id)
      row |> Ash.Changeset.for_update(:bump, %{count: row.count + by}) |> Ash.update!()
      :ok
    end
  end

  @impl true
  def render(_page, session_id, scope) do
    {:ok,
     %{"html" => "count=#{row(session_id).count}", "errors" => scope.errors, "bindings" => %{}}}
  end

  defp row(session_id) do
    case Ash.get(GuardedPage, session_id) do
      {:ok, row} -> row
      _missing -> Ash.create!(GuardedPage, %{session_id: session_id}, action: :mount)
    end
  end
end

defmodule AshAi.Test.Page do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi], validate_config_inclusion?: false

  alias AshAi.Test.Page.{CounterPage, Item}

  resources do
    resource CounterPage
    resource Item
    resource AshAi.Test.Page.GuardedPage
  end

  tools do
    tool :show_counter, Item, :read, ui: :counter
    tool :list_items, Item, :read
  end

  mcp_resources do
    mcp_ui_resource :counter, "ui://counter/view", page: CounterPage, title: "Counter"
    mcp_ui_resource :static, "ui://static/view.html", html_path: "test/support/page.ex"
    mcp_ui_resource :guarded, "ui://guarded/view", page: AshAi.Test.Page.GuardedPage
  end
end
