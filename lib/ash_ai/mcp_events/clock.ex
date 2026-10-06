# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Clock do
  @moduledoc """
  The clock MCP Events reads (BLENDED-026): `DateTime.utc_now/0`, or the `utc_now/0` of the
  module configured as `config :ash_ai, :mcp_events_clock, MyClock` (tests use a settable one).

  It stamps occurrences, grants TTLs, opens and closes rotation windows, ages the verification
  cache and dates webhook signatures. The AshQueue templates (`expire`, `prune`) compare with
  Ash's `now()`; the bodies re-check expiry with this clock, so a subscription past its
  `expires_at` is never delivered to, whichever clock noticed first.
  """

  @callback utc_now() :: DateTime.t()

  @doc "The current instant."
  @spec utc_now() :: DateTime.t()
  def utc_now do
    case Application.get_env(:ash_ai, :mcp_events_clock) do
      nil -> DateTime.utc_now()
      module -> module.utc_now()
    end
  end
end
