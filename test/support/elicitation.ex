# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-023 (see BLENDED.md): orders whose tools ask the user for missing
# input. Every action that runs records itself in `Run`, so a test can count the runs.

defmodule AshAi.Test.Elicitation.Size do
  @moduledoc false
  use Ash.Type.Enum, values: [:small, :large]
end

defmodule AshAi.Test.Elicitation.Order do
  @moduledoc false
  use Ash.Resource,
    domain: AshAi.Test.Elicitation,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :part, :string, public?: true
    attribute :quantity, :integer, public?: true
    attribute :note, :string, public?: true
    attribute :label, :string, public?: true, description: "A label for the order."
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  actions do
    defaults [:read, :destroy]

    create :place do
      accept [:note]

      argument :part, :string,
        allow_nil?: false,
        public?: true,
        description: "The part to order."

      argument :quantity, :integer,
        allow_nil?: false,
        public?: true,
        constraints: [min: 1, max: 10]

      argument :code, :string,
        public?: true,
        constraints: [match: ~r/^[A-Z]{3}$/, min_length: 3, max_length: 3]

      argument :size, AshAi.Test.Elicitation.Size, public?: true
      argument :finish, :atom, public?: true, constraints: [one_of: [:matte, :gloss]]
      argument :express, :boolean, public?: true
      argument :due, :date, public?: true
      argument :weight, :float, public?: true, constraints: [min: 0.5, max: 99.5]

      argument :colors, {:array, :atom},
        public?: true,
        constraints: [min_length: 1, max_length: 2, items: [one_of: [:red, :blue, :green]]]

      validate attribute_does_not_equal(:note, "forbidden")

      change set_attribute(:part, arg(:part))
      change set_attribute(:quantity, arg(:quantity))
    end

    create :place_with_label do
      accept [:label]
      require_attributes [:label]
      argument :part, :string, allow_nil?: false, public?: true
    end

    create :attach do
      argument :spec, :map, allow_nil?: false, public?: true
      argument :part, :string, allow_nil?: false, public?: true
      change set_attribute(:part, arg(:part))
    end

    update :reprice do
      require_atomic? false
      argument :quantity, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
      change set_attribute(:quantity, arg(:quantity))
    end

    read :by_part do
      argument :part, :string, allow_nil?: false, public?: true
      filter expr(part == ^arg(:part))
    end

    action :quote, :string do
      argument :part, :string, allow_nil?: false, public?: true
      argument :quantity, :integer, allow_nil?: false, public?: true, constraints: [max: 5]

      run fn input, _context ->
        {:ok, "#{input.arguments.quantity} x #{input.arguments.part}"}
      end
    end
  end
end

defmodule AshAi.Test.Elicitation.Endpoint do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.Elicitation, extensions: [AshAi.McpActions]

  mcp_actions do
    actions([{AshAi.Test.Elicitation.Order, :*}])
    tools([:place_order])
  end
end

defmodule AshAi.Test.Elicitation do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi], validate_config_inclusion?: false

  alias AshAi.Test.Elicitation.Order

  resources do
    resource Order
    resource AshAi.Test.Elicitation.Endpoint
  end

  tools do
    tool :place_order, Order, :place, elicit_missing?: true
    tool :place_order_plain, Order, :place
    tool :place_labelled, Order, :place_with_label, elicit_missing?: true
    tool :attach_spec, Order, :attach, elicit_missing?: true
    tool :reprice_order, Order, :reprice, elicit_missing?: true
    tool :orders_by_part, Order, :by_part, elicit_missing?: true
    tool :quote_order, Order, :quote, elicit_missing?: true
  end
end
