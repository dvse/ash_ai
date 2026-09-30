# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.DeliveryHints do
  @moduledoc """
  An `expose` block's delivery hints (BLENDED-015, the module form of BLENDED-008's
  `delivery_hints`).

  `delivery_hints` accepts a function `fn context -> [map()] | nil end`, a module implementing
  this behaviour, or `{module, opts}`, in the idiom Ash uses for a generic action's `run`. A
  function is stored as `{AshAi.DeliveryHints.Function, fun: fun}`.

  ### Example

      defmodule MyApp.PostDeliveryHints do
        use AshAi.DeliveryHints

        @impl true
        def delivery_hints(%{result: %{id: id}}, _opts),
          do: [%{note: "Comment on it", action: :comment, args: %{post_id: id}}]

        def delivery_hints(_context, _opts), do: nil
      end

      expose MyApp.Blog.Post do
        delivery_hints MyApp.PostDeliveryHints
        interface :comment
      end
  """

  @doc """
  Receives `%{tool:, resource:, action:, arguments:, result:}` and the option's `opts`; returns a
  list of hint maps (`note`, `action`, `args`, optional `resource`) or `nil`.
  """
  @callback delivery_hints(context :: map(), opts :: Keyword.t()) :: [map()] | nil

  defmacro __using__(_opts) do
    quote do
      @behaviour AshAi.DeliveryHints
    end
  end
end

defmodule AshAi.DeliveryHints.Function do
  @moduledoc false
  # BLENDED-015: the function form of `delivery_hints`.
  use AshAi.DeliveryHints

  @impl true
  def delivery_hints(context, fun: fun), do: fun.(context)
end
