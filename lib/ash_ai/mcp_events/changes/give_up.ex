# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Changes.GiveUp do
  @moduledoc """
  The `give_up` edge of a delivery (BLENDED-026): the commanded `pending -> failed` transition the
  `deliver` edge's exhaustion routes through after its fifth failed attempt. It records the last
  attempt's error and number; the machine injects the state write.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    error = Ash.Changeset.get_argument(changeset, :error)
    attempt = Ash.Changeset.get_argument(changeset, :attempt)

    Logger.info(
      "MCP Events delivery #{changeset.data.id}: giving up on event #{changeset.data.event_id} after #{attempt} attempts"
    )

    changeset
    |> Ash.Changeset.force_change_attribute(:last_error, message(error))
    |> then(fn changeset ->
      if is_integer(attempt),
        do: Ash.Changeset.force_change_attribute(changeset, :attempt, attempt),
        else: changeset
    end)
  end

  defp message(nil), do: nil
  defp message(error) when is_binary(error), do: error
  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)
end
