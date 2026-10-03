# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-022 (see BLENDED.md): documents owned by a caller, served as one MCP
# resource per row. The content actions read the row WITHOUT authorization, so only the
# server's own read of the row as the caller keeps another caller's documents unreadable. Every
# list action pages (`default_limit`), as the verifier requires; `required?: false` keeps the
# tests' own reads unpaged.

defmodule AshAi.Test.RowResources.Doc do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.RowResources,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? false
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :summary, :string, public?: true
    attribute :owner, :string, public?: true
    attribute :body, :string, public?: true
    attribute :secret, :string
  end

  policies do
    policy action([:read, :titled]) do
      authorize_if expr(owner == ^actor(:name))
    end

    policy action([:everything, :first_two]) do
      authorize_if always()
    end

    policy action_type(:action) do
      authorize_if actor_present()
    end

    policy action_type([:create, :destroy]) do
      authorize_if always()
    end
  end

  actions do
    defaults [:destroy, create: [:id, :title, :summary, :owner, :body, :secret]]

    read :read do
      primary? true
      pagination offset?: true, default_limit: 50, required?: false
    end

    read :everything do
      pagination offset?: true, default_limit: 50, required?: false
    end

    read :titled do
      filter expr(not is_nil(title))
      pagination offset?: true, default_limit: 50, required?: false
    end

    read :first_two do
      pagination offset?: true, default_limit: 2, required?: false
    end

    read :unbounded

    read :no_default do
      pagination offset?: true, required?: false
    end

    action :markdown, :string do
      description "A document as Markdown."
      argument :id, :string, allow_nil?: false
      argument :style, :string

      run fn input, context ->
        doc = Ash.get!(__MODULE__, input.arguments.id, authorize?: false)

        {:ok,
         "# #{doc.title}\n\n#{doc.body}\n\n(read by #{context.actor.name}" <>
           if(input.arguments[:style], do: ", #{input.arguments.style})", else: ")")}
      end
    end

    action :by_owner, :string do
      argument :owner, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, "#{input.arguments.owner}/#{input.arguments.id}"}
      end
    end

    action :bytes, :binary do
      argument :id, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, <<0, 255>> <> input.arguments.id}
      end
    end

    action :as_map, :map do
      argument :id, :string, allow_nil?: false
      run fn _input, _context -> {:ok, %{}} end
    end

    action :broken, :string do
      argument :id, :string, allow_nil?: false
      run fn _input, _context -> {:error, "the document could not be rendered"} end
    end
  end
end

defmodule AshAi.Test.RowResources.NoPrimary do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.RowResources, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    read :all do
      pagination offset?: true, default_limit: 50, required?: false
    end

    create :create, accept: [:id]
    destroy :destroy

    action :show, :string do
      argument :id, :integer, allow_nil?: false
      run fn input, _context -> {:ok, "number #{input.arguments.id}"} end
    end
  end
end

defmodule AshAi.Test.RowResources.Loose do
  @moduledoc false
  # A primary read without pagination: a template over it must declare a bounded `list`.
  use Ash.Resource, domain: AshAi.Test.RowResources, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    action :show, :string do
      argument :id, :integer, allow_nil?: false
      run fn input, _context -> {:ok, "loose #{input.arguments.id}"} end
    end
  end
end

defmodule AshAi.Test.RowResources do
  @moduledoc false
  use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

  resources do
    resource AshAi.Test.RowResources.Doc
    resource AshAi.Test.RowResources.NoPrimary
    resource AshAi.Test.RowResources.Loose
  end

  mcp_resources do
    mcp_resource_template(
      :doc,
      "docs://docs/{id}",
      AshAi.Test.RowResources.Doc,
      :markdown,
      title: "Document",
      mime_type: "text/markdown",
      row_name: :id,
      row_title: :title,
      row_description: :summary
    )

    mcp_resource_template(
      :owned,
      "docs://owners/{owner}/docs/{id}",
      AshAi.Test.RowResources.Doc,
      :by_owner,
      title: "Owned document",
      description: "A document under its owner.",
      list: :titled
    )

    mcp_resource_template(
      :bytes,
      "docs://bytes/{id}",
      AshAi.Test.RowResources.Doc,
      :bytes,
      title: "Document bytes",
      mime_type: "application/octet-stream"
    )

    mcp_resource_template(
      :broken,
      "docs://broken/{id}",
      AshAi.Test.RowResources.Doc,
      :broken,
      title: "Broken"
    )

    mcp_resource_template(
      :everyone,
      "docs://all/{id}",
      AshAi.Test.RowResources.Doc,
      :markdown,
      title: "Every document",
      list: :everything
    )

    mcp_resource_template(
      :first_two,
      "docs://first/{id}",
      AshAi.Test.RowResources.Doc,
      :markdown,
      title: "First two documents",
      list: :first_two
    )

    mcp_resource_template(:number, "numbers://{id}", AshAi.Test.RowResources.NoPrimary, :show,
      title: "Number",
      list: :all
    )
  end
end
