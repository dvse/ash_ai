# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Mcp.Icons do
  @moduledoc """
  MCP 2025-11-25 `Icon`s (BLENDED-021): `serverInfo.icons` (the `mcp_icons` server option) and a
  tool's `icons` option.

  An icon is a map with atom or string keys: `src` (required, an `https:`, `http:` or `data:`
  URL), `mime_type`/`mimeType`, `sizes` (a list of strings such as `"any"` or `"48x48"`) and
  `theme` (`"light"` or `"dark"`). The wire form uses MCP's camelCase names.
  """

  @doc """
  The wire form of a list of icons, or `nil` when there are none. Raises `ArgumentError`, naming
  the subject, for anything that is not an icon.
  """
  def normalize(nil, _subject), do: nil
  def normalize([], _subject), do: nil

  def normalize(icons, subject) when is_list(icons), do: Enum.map(icons, &icon!(&1, subject))

  def normalize(other, subject),
    do: raise(ArgumentError, "#{subject}: icons must be a list of maps, got: #{inspect(other)}")

  defp icon!(icon, subject) when is_map(icon) do
    src = get(icon, :src)
    mime_type = get(icon, :mime_type) || get(icon, :mimeType)
    sizes = get(icon, :sizes)
    theme = get(icon, :theme)
    known = ~w(src mime_type mimeType sizes theme)
    unknown = icon |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in known))

    cond do
      unknown != [] ->
        bad!(subject, icon, "unknown keys #{Enum.join(Enum.sort(unknown), ", ")}")

      not (is_binary(src) and String.match?(src, ~r/^(https?:|data:)/)) ->
        bad!(subject, icon, "src must be an https:, http: or data: URL")

      not (is_nil(mime_type) or is_binary(mime_type)) ->
        bad!(subject, icon, "mime_type must be a string")

      not (is_nil(sizes) or (is_list(sizes) and Enum.all?(sizes, &is_binary/1))) ->
        bad!(subject, icon, "sizes must be a list of strings")

      theme not in [nil, "light", "dark", :light, :dark] ->
        bad!(subject, icon, "theme must be \"light\" or \"dark\"")

      true ->
        %{"src" => src}
        |> put("mimeType", mime_type)
        |> put("sizes", sizes)
        |> put("theme", theme && to_string(theme))
    end
  end

  defp icon!(icon, subject), do: bad!(subject, icon, "an icon must be a map")

  defp bad!(subject, icon, reason),
    do: raise(ArgumentError, "#{subject}: #{reason}, got: #{inspect(icon)}")

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp get(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
