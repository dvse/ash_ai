# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Test support for BLENDED-016 and BLENDED-018 (see BLENDED.md): a documents domain whose tools
# take OpenAI Apps SDK file objects and declare security schemes, served through an
# `AshAi.McpActions` endpoint.

defmodule AshAi.Test.OpenAi.Document do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.OpenAi

  actions do
    action :attach, :map do
      argument :id, :string, allow_nil?: false, public?: true
      argument :note, :string, public?: true
      argument :file, :map, public?: true
      argument :files, {:array, :map}, public?: true

      run fn input, context ->
        {:ok,
         %{
           "id" => input.arguments.id,
           "note" => Map.get(input.arguments, :note),
           "file" => Map.get(input.arguments, :file),
           "files" => Map.get(input.arguments, :files),
           "mcp_files" => context.source_context |> Map.get(:mcp_files) |> length_of()
         }}
      end
    end

    action :scan, :map do
      argument :file, :map, allow_nil?: false, public?: true

      run fn input, _context -> {:ok, %{"file_id" => input.arguments.file["file_id"]}} end
    end

    action :ping, :string do
      run fn _input, _context -> {:ok, "pong"} end
    end

    action :wrong, :string do
      argument :count, :integer, public?: true
      run fn _input, _context -> {:ok, "never"} end
    end
  end

  defp length_of(list) when is_list(list), do: length(list)
  defp length_of(_), do: nil
end

defmodule AshAi.Test.OpenAi.Endpoint do
  @moduledoc false
  use Ash.Resource, domain: AshAi.Test.OpenAi, extensions: [AshAi.McpActions]

  mcp_actions do
    actions([{AshAi.Test.OpenAi.Document, :*}])
    tools([:attach_document, :scan_file, :ping])
    security_schemes([%{type: "oauth2", scopes: ["mcp"]}])
  end
end

defmodule AshAi.Test.OpenAi do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_ai, extensions: [AshAi]

  alias AshAi.Test.OpenAi.Document

  tools do
    tool :attach_document, Document, :attach,
      file_params: [:file, :files],
      security_schemes: [%{type: "oauth2", scopes: ["mcp"]}],
      _meta: %{"openai/toolInvocation/invoking" => "Attaching…"}

    tool :scan_file, Document, :scan, file_params: [:file], security_schemes: [%{type: "noauth"}]
    tool :ping, Document, :ping
    tool :wrong_files, Document, :wrong, file_params: [:count]
    tool :missing_files, Document, :ping, file_params: [:nothing]
    tool :bad_scheme, Document, :ping, security_schemes: [%{type: "basic"}]
  end

  resources do
    resource Document
    resource AshAi.Test.OpenAi.Endpoint
  end
end
