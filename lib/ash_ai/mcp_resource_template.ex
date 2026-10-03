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
  public attribute of the resource and an argument of the action.

  * `resources/templates/list` lists the template (`uriTemplate`, `name`, `title`,
    `description`, `mimeType`).
  * `resources/list` lists one resource per row the `list` read action (default: the primary
    read) returns for the caller: `uri` is the template expanded with the row's values, `name`
    the `row_name` field (default: the URI), `title` and `description` the `row_title` and
    `row_description` fields when set, `mimeType` the template's. A row with a nil variable is
    not listed. There is no cursor: the list action bounds the list (pagination's default limit,
    a preparation).
  * `resources/read` of a URI the template matches reads that row through the `list` action,
    filtered by the extracted values, as the caller; a row the caller cannot read (or none) is
    "Resource not found". The action then runs with the values as arguments (and the read
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

  @doc """
  The template's variable names, in order, or `{:error, message}` when the template is not
  RFC 6570 level 1 with at least one variable.
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
  `expand/2` writes.
  """
  @spec match(String.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | :error
  def match(uri_template, uri) do
    {names, pattern} =
      Regex.split(@expression, uri_template, include_captures: true)
      |> Enum.reduce({[], ""}, fn part, {names, pattern} ->
        case Regex.run(@expression, part, capture: :all_but_first) do
          [name] -> {[name | names], pattern <> "((?:[A-Za-z0-9\\-._~]|%[0-9A-Fa-f]{2})+)"}
          nil -> {names, pattern <> Regex.escape(part)}
        end
      end)

    case Regex.run(Regex.compile!("^" <> pattern <> "$"), uri) do
      [_ | captures] ->
        {:ok, names |> Enum.reverse() |> Enum.zip(Enum.map(captures, &URI.decode/1)) |> Map.new()}

      nil ->
        :error
    end
  end
end
