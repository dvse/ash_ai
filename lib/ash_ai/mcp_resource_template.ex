# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.McpResourceTemplate do
  @moduledoc """
  Row-backed MCP resources (BLENDED-022): one MCP resource per row of an Ash resource.

  ```elixir
  mcp_resources do
    mcp_resource_template :part, "mcp://parts/{id}", Part, :markdown,
      title: "CAD part",
      mime_type: "text/markdown",
      row_name: :id,
      row_title: :name,
      row_description: :description
  end
  ```

  The URI template uses RFC 6570 level 1 (`{var}`, simple string expansion); every variable is a
  public attribute of the resource and an argument of the action, and a literal separates every
  two variables (`{a}{b}` could split a URI either way).

  * `resources/templates/list` lists the template (`uriTemplate`, `name`, `title`,
    `description`, `mimeType`).
  * `resources/list` lists one resource per row the `list` read action (default: the primary
    read) returns for the caller: `uri` is the template expanded with the row's values, `name`
    the `row_name` field (default: the URI), `title` and `description` the `row_title` and
    `row_description` fields when set, `mimeType` the template's. A row with a nil variable is
    not listed. There is no cursor: the list action must declare pagination with a
    `default_limit`, and the listing reads one page of that size.
  * `resources/read` of a URI the template matches reads that row through the `list` action,
    filtered by the extracted values, as the caller; a row the caller cannot read (or none) is
    "Resource not found" (a row beyond the listed page is still readable). The action then runs with the values as arguments (and the read
    request's params for its other arguments, as `mcp_resource`), and its result is the
    content: `text` for a string, `blob` (base64) for `Ash.Type.Binary`.

  Notifications (`listChanged`, subscriptions) are not sent.
  """

  @type t :: %__MODULE__{
          name: atom(),
          uri_template: String.t(),
          resource: Ash.Resource.t(),
          action: atom() | Ash.Resource.Actions.Action.t(),
          list: atom() | Ash.Resource.Actions.Read.t() | nil,
          domain: module() | nil,
          title: String.t(),
          description: String.t() | nil,
          mime_type: String.t(),
          row_name: atom() | nil,
          row_title: atom() | nil,
          row_description: atom() | nil
        }

  defstruct [
    :name,
    :uri_template,
    :resource,
    :action,
    :list,
    :domain,
    :title,
    :description,
    :mime_type,
    :row_name,
    :row_title,
    :row_description,
    __spark_metadata__: nil
  ]

  @expression ~r/\{([^}]*)\}/
  @variable ~r/^[A-Za-z0-9_]+$/

  @adjacent ~r/\{([^{}]*)\}\{([^{}]*)\}/

  @doc """
  The template's variable names, in order, or `{:error, message}` when the template is not
  RFC 6570 level 1 with at least one variable and a literal between every two variables.
  """
  @spec variables(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def variables(uri_template) do
    names =
      @expression
      |> Regex.scan(uri_template, capture: :all_but_first)
      |> Enum.map(fn [name] -> name end)

    literal = Regex.replace(@expression, uri_template, "")

    cond do
      names == [] ->
        {:error, "has no {variable}"}

      bad = Enum.find(names, &(not Regex.match?(@variable, &1))) ->
        {:error, "has {#{bad}}, which is not a simple {variable}"}

      String.contains?(literal, ["{", "}"]) ->
        {:error, "has an unbalanced brace"}

      Enum.uniq(names) != names ->
        {:error, "repeats a variable"}

      adjacent = Regex.run(@adjacent, uri_template, capture: :all_but_first) ->
        [left, right] = adjacent
        {:error, "has {#{left}}{#{right}}: no literal separates the two variables"}

      true ->
        {:ok, names}
    end
  end

  @doc """
  Expands the template with `values` (a map from variable name to value): each value is its
  string form, percent-encoded except for unreserved characters (RFC 6570 simple expansion).
  `nil` when a value is missing or nil.
  """
  @spec expand(String.t(), %{optional(String.t()) => term()}) :: String.t() | nil
  def expand(uri_template, values) do
    Regex.split(@expression, uri_template, include_captures: true)
    |> Enum.reduce_while("", fn part, acc ->
      case Regex.run(@expression, part, capture: :all_but_first) do
        [name] ->
          case Map.get(values, name) do
            nil ->
              {:halt, nil}

            value ->
              {:cont, acc <> URI.encode(to_string(value), &URI.char_unreserved?/1)}
          end

        nil ->
          {:cont, acc <> part}
      end
    end)
  end

  @doc """
  Matches `uri` against the template: `{:ok, values}` (variable name to decoded value) or
  `:error`. A variable matches one or more unreserved characters or `%XX` escapes, what
  `expand/2` writes; the whole URI must match. Where a literal could end a variable at more than
  one place, each variable takes the longest span that lets the rest match (a greedy regular
  expression's choice), found in time linear in the URI's length for each variable (a
  backtracking regular expression costs polynomial time on a long URI that does not match, and
  gives up at its match limit).
  """
  @spec match(String.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | :error
  def match(uri_template, uri) do
    {literals, names} = parts(uri_template)
    [first | rest] = literals

    if String.starts_with?(uri, first) do
      size = byte_size(uri)
      next = token_ends(uri, size)
      fars = farthest_ends(uri, size, next, rest)
      take(uri, byte_size(first), Enum.zip([names, rest, fars]), %{})
    else
      :error
    end
  end

  # The template as its literals (one more than its variables) and its variable names.
  defp parts(uri_template) do
    Regex.split(@expression, uri_template, include_captures: true)
    |> Enum.reduce({[""], []}, fn part, {[literal | literals], names} ->
      case Regex.run(@expression, part, capture: :all_but_first) do
        [name] -> {["", literal | literals], [name | names]}
        nil -> {[literal <> part | literals], names}
      end
    end)
    |> then(fn {literals, names} -> {Enum.reverse(literals), Enum.reverse(names)} end)
  end

  # `next[p]`: where the variable token starting at `p` (an unreserved character or a `%XX`
  # escape) ends, or nil. A variable's span from `p` ends only on this chain.
  defp token_ends(uri, size) do
    0..size
    |> Enum.map(fn p ->
      case uri do
        <<_::binary-size(^p), c, _::binary>> when c in ?a..?z or c in ?A..?Z or c in ?0..?9 ->
          p + 1

        <<_::binary-size(^p), c, _::binary>> when c in [?-, ?., ?_, ?~] ->
          p + 1

        <<_::binary-size(^p), ?%, h1, h2, _::binary>> ->
          if hex?(h1) and hex?(h2), do: p + 3, else: nil

        _ ->
          nil
      end
    end)
    |> List.to_tuple()
  end

  defp hex?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # For each variable (with the literal after it), a tuple `far` where `far[p]` is the farthest
  # end of that variable's span from `p` that lets the rest of the URI match, or nil. Computed
  # from the last variable back, each in one right-to-left pass.
  defp farthest_ends(uri, size, next, literals_after) do
    literals_after
    |> Enum.reverse()
    |> Enum.reduce({[], fn p -> p == size end}, fn literal, {fars, rest_matches?} ->
      ends? = fn q ->
        after_literal = q + byte_size(literal)

        after_literal <= size and binary_part(uri, q, byte_size(literal)) == literal and
          rest_matches?.(after_literal)
      end

      far =
        size..0//-1
        |> Enum.reduce(%{}, fn p, far ->
          case elem(next, p) do
            nil ->
              far

            q ->
              case Map.get(far, q) || if(ends?.(q), do: q) do
                nil -> far
                found -> Map.put(far, p, found)
              end
          end
        end)

      {[far | fars], &Map.has_key?(far, &1)}
    end)
    |> elem(0)
  end

  defp take(_uri, _p, [], values), do: {:ok, values}

  defp take(uri, p, [{name, literal, far} | rest], values) do
    case Map.get(far, p) do
      nil ->
        :error

      q ->
        value = URI.decode(binary_part(uri, p, q - p))
        take(uri, q + byte_size(literal), rest, Map.put(values, name, value))
    end
  end
end
