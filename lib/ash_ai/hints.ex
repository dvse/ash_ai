# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Hints do
  @moduledoc """
  A tool's result hint (BLENDED-015, the module form of BLENDED-007's `hints`).

  `hints` accepts a function `fn result -> String.t() | nil end`, a module implementing this
  behaviour, or `{module, opts}`, in the idiom Ash uses for a generic action's `run`
  (`{:spark_function_behaviour, Ash.Resource.Actions.Implementation,
  {Ash.Resource.Action.ImplementationFunction, 2}}`). A function is stored as
  `{AshAi.Hints.Function, fun: fun}`.

  ### Example

      defmodule MyApp.NextFieldHint do
        use AshAi.Hints

        @impl true
        def hint(%{next: next}, _opts) when is_binary(next), do: "Next: \#{next}."
        def hint(_result, _opts), do: nil
      end

      tool :set_fund_details, Case, :set_fund_details, hints: MyApp.NextFieldHint
  """

  @doc """
  Receives the raw (map) action result and the option's `opts`; returns the model-facing hint
  text, or `nil` for none.
  """
  @callback hint(result :: term(), opts :: Keyword.t()) :: String.t() | nil

  defmacro __using__(_opts) do
    quote do
      @behaviour AshAi.Hints
    end
  end
end

defmodule AshAi.Hints.Function do
  @moduledoc false
  # BLENDED-015: the function form of `hints`, as `Ash.Resource.Action.ImplementationFunction`
  # is the function form of a generic action's `run`.
  use AshAi.Hints

  @impl true
  def hint(result, fun: fun), do: fun.(result)
end
