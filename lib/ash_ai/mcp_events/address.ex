# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpEvents.Address do
  @moduledoc """
  Which addresses a callback may reach (BLENDED-026): Oberon's `isPublicAddress` table
  (`src/webhook.ts`), ported exactly.
  """

  import Bitwise

  @ipv4_blocked [
    {"0.0.0.0", 8},
    {"10.0.0.0", 8},
    {"100.64.0.0", 10},
    {"127.0.0.0", 8},
    {"169.254.0.0", 16},
    {"172.16.0.0", 12},
    {"192.0.0.0", 24},
    {"192.0.2.0", 24},
    {"192.168.0.0", 16},
    {"198.18.0.0", 15},
    {"198.51.100.0", 24},
    {"203.0.113.0", 24},
    {"224.0.0.0", 4},
    {"240.0.0.0", 4}
  ]

  @ipv6_blocked [
    {"::", 128},
    {"::1", 128},
    {"64:ff9b::", 96},
    {"100::", 64},
    {"2001:db8::", 32},
    {"fc00::", 7},
    {"fe80::", 10},
    {"ff00::", 8}
  ]

  @doc """
  True for an address on the public internet; false for private, local, reserved and mapped
  addresses, and for anything that is not an IP address literal. An IPv4-mapped IPv6 address
  written with a dotted quad (`::ffff:a.b.c.d`) is judged by its IPv4 address; any other
  `::ffff:` form is refused.
  """
  @spec public?(String.t()) :: boolean()
  def public?(address) when is_binary(address) do
    case Regex.run(~r/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i, address) do
      [_, mapped] ->
        public?(mapped)

      nil ->
        case :inet.parse_strict_address(String.to_charlist(address)) do
          {:ok, ip} when tuple_size(ip) == 4 ->
            not blocked?(ip, ipv4_blocks())

          {:ok, ip} when tuple_size(ip) == 8 ->
            not Regex.match?(~r/^::ffff:/i, address) and not blocked?(ip, ipv6_blocks())

          _ ->
            false
        end
    end
  end

  def public?(_address), do: false

  @doc "True when `host` is an IP address literal (brackets around an IPv6 literal are allowed)."
  @spec ip_literal?(String.t()) :: boolean()
  def ip_literal?(host) do
    match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(unbracket(host))))
  end

  @doc "`localhost` and every `*.localhost` name."
  @spec localhost?(String.t()) :: boolean()
  def localhost?(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    host == "localhost" or String.ends_with?(host, ".localhost")
  end

  @doc false
  def unbracket(host), do: host |> String.trim_leading("[") |> String.trim_trailing("]")

  defp blocked?(ip, blocks) do
    value = to_integer(ip)
    Enum.any?(blocks, fn {network, mask} -> (value &&& mask) == network end)
  end

  defp ipv4_blocks, do: Enum.map(@ipv4_blocked, &block(&1, 32))
  defp ipv6_blocks, do: Enum.map(@ipv6_blocked, &block(&1, 128))

  defp block({network, prefix}, bits) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(network))
    mask = (1 <<< bits) - (1 <<< (bits - prefix))
    {to_integer(ip) &&& mask, mask}
  end

  defp to_integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp to_integer({_, _, _, _, _, _, _, _} = ip) do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
  end
end
