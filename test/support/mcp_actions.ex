# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-014 (`AshAi.McpActions`, see BLENDED.md): a small notes domain whose
# tools are served through the synthesized `:mcp` action of two endpoint resources.

defmodule AshAi.Test.McpActions.Note do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.McpActions,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :owner, :string, public?: true
  end

  policies do
    policy action(:create) do
      authorize_if actor_present()
    end

    policy action(:guarded_create) do
      authorize_if AshAi.Test.Blended.DiscoveryOnly
    end

    policy always() do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title]
      change fn changeset, context -> set_owner(changeset, context.actor) end
    end

    create :guarded_create do
      accept [:title]
    end

    action :whoami, :map do
      run fn _input, context -> {:ok, %{"name" => context.actor && context.actor.name}} end
    end

    action :card, :string do
      run fn _input, context -> {:ok, "card for #{context.actor && context.actor.name}"} end
    end
  end

  defp set_owner(changeset, actor),
    do: Ash.Changeset.force_change_attribute(changeset, :owner, actor && actor.name)
end

defmodule AshAi.Test.McpActions.Endpoint do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.McpActions,
    extensions: [AshAi.McpActions]

  mcp_actions do
    actions([{AshAi.Test.McpActions.Note, :*}])
    mcp_name("notes")
    mcp_server_version("1.2.3")
    instructions("Use the notes tools.")
  end
end

defmodule AshAi.Test.McpActions.PrivateEndpoint do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.McpActions,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAi.McpActions]

  mcp_actions do
    mcp_action_name(:handle)
    otp_app(:ash_ai)
    actions([{AshAi.Test.McpActions.Note, :*}])
    tools([:list_notes, :create_note])
    exclude_actions([{AshAi.Test.McpActions.Note, :card}])
    mcp_resources([:note_card, :note_app])
    forbidden_fields :display
    strict(true)
    protocol_version_statement("2025-03-26")
    list_ttl_ms(5_000)
    read_ttl_ms(1_000)
    cache_scope("public")
    resource_metadata_url("https://notes.example/.well-known/oauth-protected-resource")
  end

  policies do
    policy action(:handle) do
      authorize_if actor_present()
    end
  end
end

defmodule AshAi.Test.McpActions do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi]

  alias AshAi.Test.McpActions.Note

  tools do
    tool :list_notes, Note, :read, annotations: [title: "List notes"]
    tool :create_note, Note, :create
    tool :guarded_note, Note, :guarded_create
    tool :whoami, Note, :whoami
  end

  mcp_resources do
    mcp_resource :note_card, "file://notes/card", Note, :card do
      title "Note Card"
      mime_type "text/plain"
    end

    mcp_ui_resource :note_app, "ui://notes/app.html",
      html_path: "test/fixtures/test_app.html",
      title: "Notes App",
      domain: :auto
  end

  resources do
    resource Note
    resource AshAi.Test.McpActions.Endpoint
    resource AshAi.Test.McpActions.PrivateEndpoint
  end
end
