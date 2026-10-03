# ash_ai — Hyperbob blended port target

Branch `hyperbob/blended` of ash-project/ash_ai, based on upstream `2a0a538` (2026-09-27).
This branch is the **reference implementation and parity oracle** for Bobstack's `ai` chapter.
Bobstack ports THIS branch faithfully, row for row, with `@port` markers pointing here.
Everything upstream stays as upstream has it. Every addition is ledgered below with its
`BLENDED-*` id and its source in `~/projects/agents/ash_hyperlang` (fe58ddd). Nothing is
invented. An addition is either (a) ash_hyperlang's DSL/behaviour applied to ash_ai tools, or (b) the
MCP tool fields the MCP spec defines (`title`, `annotations`, `outputSchema`), derived from
core Ash (`Ash.Info.Manifest`, action types, action metadata).

## DSL (domain and resource `tools` section)

Unchanged upstream entities: `tool`, `argument`, `mcp_resources`, `mcp_resource`, `mcp_ui_resource` (which gains `page`, BLENDED-020). New in `mcp_resources`: `mcp_resource_template` (BLENDED-022).

| Id | Addition | Shape | Source |
|---|---|---|---|
| BLENDED-001 | `expose` entity in `tools` (domain level) | `expose Resource do interface :define_name, opts end`. Each `interface` becomes one tool named after the interface, calling the action behind that domain `define`. | ash_hyperlang `domain.ex` `@expose`/`@interface`, `Info.declared_actions/1` |
| BLENDED-002 | Verifier for `expose` | The resource must be in the domain's `resources` block, the interface must match a `define`, and the action must be public (non-public is skipped, as hyperlang does). Tool names stay unique across `tool` and `interface`. | hyperlang `Verifiers.VerifyExposures`; ash_ai `ash_ai.ex` uniqueness |
| BLENDED-003 | `example` option (on `tool` and `interface`) | Worked example string, appended to the tool description. | hyperlang `interface example:` |
| BLENDED-004 | `refine?` option (default true) | `false` omits the read query envelope (filter/sort/limit/offset/result_type). Equivalent to upstream `action_parameters: []`; both are accepted and must agree. | hyperlang `refine?` |
| BLENDED-005 | `blocking?` option | Default comes from the action's own `metadata :blocking?` declaration (or `:await`). An explicit option overrides. Surfaces as `_meta["hyperbob/blocking"]` and in the description. | hyperlang `surface.ex` `blocking?/3`, `blocking_action?/2` |
| BLENDED-006 | `continuation_target?` option (default false) | Marks tools whose calls may park as await continuations. Metadata only. | hyperlang `continuation_target` |
| BLENDED-007 | `hints` option, a `fn result -> String.t() | nil` (or a module, BLENDED-015) | Its text is appended as a second text `content` block (model-facing). `structuredContent` is unchanged. | hyperlang `hints`, executor `result_hints_doc` |
| BLENDED-008 | `delivery_hints` entity on `expose` | A per-resource callback (or a module, BLENDED-015) returning a list of hint maps, attached to results for that resource. | hyperlang `@delivery_hints` |
| BLENDED-009 | `annotations` option (on `tool` and `interface`) | `title`, `read_only?`, `destructive?`, `idempotent?`, `open_world?`. Defaults from the action type: read → read_only true, destructive false; create → false/false; update/destroy → false/true; generic → from `metadata :read_only?`/`:destructive?` if declared, else read_only false, destructive true. `open_world?` defaults false. | MCP spec `ToolAnnotations`; carrier pattern from hyperlang `blocking?` (action metadata) |
| BLENDED-010 | `output_schema?` option (default true when the result is a map) | Emits MCP `outputSchema` from `Ash.Info.Manifest` (generic `returns`; read/create/update results as the resource's public fields honouring `select`/`load`). It must describe exactly what `structuredContent` returns. | hyperlang documents outputs via `Ash.Info.Manifest` `ActionBuilder` `returns`; MCP spec `outputSchema` |
| BLENDED-011 | Zero-input tools | When no input is required, the input schema requires nothing and `{}` is accepted (ChatGPT entrypoints need this). | hyperlang `Capability.required_arguments?`, arity-0 imports |
| BLENDED-012 | `forbidden_fields` option on the MCP server/`tools` section (`:hide` default, `:display`) | How field-policy-forbidden fields appear in results. `outputSchema` must agree. | hyperlang `eval_actions forbidden_fields` |
| BLENDED-013 | Policy breakdown on forbidden calls | The full Ash policy report is logged host-side; the caller gets a compact `isError` text with the tool name and a stable category. When the actor is nil, add `_meta["mcp/www_authenticate"]`. | hyperlang `EvalActions.PolicyBreakdown`, `GuestError.policy_denial` |
| BLENDED-014 | `AshAi.McpActions` resource extension (`mcp_actions` section) | Synthesizes one public generic action (default `:mcp`, argument `request: :map`, returns `%{status, headers, body}`) whose run builds the request as an in-memory `Plug.Conn` and calls `AshAi.Mcp.Server.handle_post/4` with the action's actor/tenant/context and the section's server options (`otp_app`, `tools`, `actions`, `mcp_resources`, `exclude_actions`, `forbidden_fields`, `strict`, `mcp_name`, `mcp_server_version`, `instructions`, `protocol_version_statement`, `list_ttl_ms`, `read_ttl_ms`, `cache_scope`, `resource_metadata_url`). A host that already exposes resource actions (Hyperbob's publication gateway) publishes an MCP endpoint as that one action. | hyperlang `AshHyperlang.EvalActions` (section, `Transformers.AddActions`, `Run.*`) |
| BLENDED-015 | Module form of `hints` and `delivery_hints` | Both options accept `fun | module | {module, opts}`, Ash's `{:spark_function_behaviour, Behaviour, {FunctionModule, arity}}` idiom, as a generic action's `run` is typed (`Ash.Resource.Actions.Action` `run:` with `Ash.Resource.Actions.Implementation` and `Ash.Resource.Action.ImplementationFunction`). Behaviours: `AshAi.Hints` (`hint(result, opts) :: String.t() | nil`) and `AshAi.DeliveryHints` (`delivery_hints(context, opts) :: [map()] | nil`); a function is stored as `{AshAi.Hints.Function, fun: fun}` / `{AshAi.DeliveryHints.Function, fun: fun}`. A declaration that cannot hold a function (Bobstack's type-level Island declaration) names a module. | Ash `run` option (`lib/ash/resource/actions/action/action.ex`, `implementation_function.ex`) |
| BLENDED-016 | `security_schemes` option (on `tool` and `interface`; default from the MCP server's / `mcp_actions` section's `security_schemes` option) | A list of `%{type: "noauth"}` or `%{type: "oauth2", scopes: [String.t()]}` (atom or string keys). `tools/list` emits it as the tool's top-level `securitySchemes` and mirrors it in `_meta["securitySchemes"]`. Unset everywhere, nothing is emitted. `AshAi.McpActions`' `request` may carry `security_schemes`: the host that authenticates the endpoint states them per request, as it states `server_url`, and they replace the section's default. Any other shape raises `ArgumentError` naming the tool. Declarative only; the host enforces authentication. | OpenAI Apps SDK reference, "Tool descriptor parameters" (`securitySchemes`, `_meta` back-compat mirror); developers.openai.com/plugins/build/auth "Triggering authentication UI" |
| BLENDED-018 | `file_params` option (on `tool` and `interface`) | Names public action arguments of type `:map` or `{:array, :map}` that take files in the Apps SDK shape `{download_url, file_id, mime_type?, file_name?}`. Each leaves the `input` envelope and becomes a top-level `inputSchema` property with exactly the SDK's file object schema (or `{type: array, items: <it>}`), required at the top level when the argument is not nullable; `_meta["openai/fileParams"]` lists the names. On `tools/call`, each file field's value is checked for that shape (an array: 1 to 20 objects) and put back into the action input; a bad value is a tool error naming the field and the action does not run. `AshAi.McpActions`' `request` may carry `files` (a list), which the action receives as `context.mcp_files`. | OpenAI Apps SDK reference, "File APIs" (`openai/fileParams`, file schema, multiple files, runtime shape) |
| BLENDED-019 | `initialize` version negotiation | A requested initialize-based revision that is supported is echoed; any other request is answered with the **latest** supported initialize-based revision (`2025-06-18`), not the oldest. **Upstream fix**: upstream answered `2025-03-26`; `protocol_2026_07_28_test.exs` ("initialize downgrades unsupported requested versions") and `mcp_action_test.exs` (an `initialize` without a version) now expect `2025-06-18`. | MCP 2025-11-25 lifecycle, "Version Negotiation" |
| BLENDED-020 | `page` option on `mcp_ui_resource` (exactly one of `html_path`/`page`): a page of the application's UI framework as an MCP Apps view (`AshAi.Page`) | The view's template (`resources/read`) is the page's client document (`c:AshAi.Page.document/2`), at the authored URI, the same for every caller. Every action the page's view binds (`c:AshAi.Page.actions/1`), and the page's `:mount` as its open tool, become ordinary tools: name `<resource>_<action>` (open tool: the page's name), `_meta.ui = {resourceUri, visibility: ["app"]}`, listed for every served page view (the `mcp_resources` option) with upstream's `can?` pre-check, independent of the `tools` option. A call of any tool whose `_meta.ui.resourceUri` names a page view runs in the caller's page session (`AshAi.Page.session_id/2`, a digest of the actor's stable identity — an Ash record's resource and primary key, else its `id`, else the term — and the page). A generated tool refuses a caller without an actor; the author's linked tool then runs as upstream, without the page. Generated names that clash with any other tool of the server are refused when the server lists its tools, with the session's Ash context and owned inputs (`c:AshAi.Page.session/2`) filled by the server and hidden from the input schema; a page-resource action first mounts the row (optional `c:AshAi.Page.mount/3`), and a framework whose page rows are reachable only through its own dispatch runs the page's tools itself (optional `c:AshAi.Page.run/4`; the result is then `Done.` or the framework's error text). Its result is upstream's, plus `_meta["ash_ai/page"]`: the page rendered after the call (`c:AshAi.Page.render/3`: the framework's own render, plus `bindings` mapping each event key to `{tool, arguments, event, accept, boundField}`), also on an `isError` result (with its error texts). The framework is the page resource's extension exporting `mcp_page_adapter/0`; ash_ai depends on none (ash_blueprint: `AshBlueprint.Phoenix.McpPage`). Upstream's `html_path` form is unchanged. | MCP Apps 2026-01-26 (`ui://` resources, `_meta.ui.resourceUri`, `visibility: ["app"]`, view-initiated `tools/call`); OpenAI Apps SDK reference (`toolResponseMetadata`: "widget-only tool result metadata"); hyperbob-cloud `reports/mcp-apps-bobstack-ui-design-2026-10-03.md` |
| BLENDED-022 | `mcp_resource_template` entity in `mcp_resources`: row-backed MCP resources, one per row (`AshAi.McpResourceTemplate`) | `mcp_resource_template :name, uri_template, Resource, :action, title:, description:, mime_type:, list:, row_name:, row_title:, row_description:`. `uri_template` is RFC 6570 level 1 (`{var}` only, at least one, none repeated); every variable is a public attribute of the resource and an argument of the action, a generic action returning `:string` (text) or `:binary` (blob); `list` (default: the primary read) is a read action; `row_*` name public attributes (`AshAi.Verifiers.VerifyMcpResourceTemplates`). `resources/templates/list` (both eras) lists each exposed template (`uriTemplate`, `name`, `title`, `description`, `mimeType`). `resources/list` adds one entry per row the `list` action returns for the caller (actor, tenant, context): `uri` the template expanded with the row's values (simple string expansion, percent-encoded), `name` the `row_name` value (default: the URI), `title`/`description` the `row_title`/`row_description` values when not nil, the template's `mimeType`; a row with a nil (or forbidden) variable is not listed. `resources/read` of a URI no static resource has matches the templates (in `uriTemplate` order), reads that row through `list` filtered by the decoded values as the caller, and only then runs the action with the values as arguments (over the read request's params for its other arguments, as upstream passes them to an `mcp_resource`). No row, a row the caller may not read, or a value the field cannot hold is "Resource not found". Exposure follows `mcp_resource`'s filters (`mcp_resources`, `actions`, `exclude_actions` over the content action). A template alone adds the `resources` capability, still without `listChanged` or `subscribe`: no notifications are sent. | MCP 2025-06-18 and 2025-11-25 server/resources (`resources/templates/list`, `ResourceTemplate`, `BlobResourceContents`); RFC 6570 level 1; OpenAI Bits & Bolts plugin (mcp-extensions 900032d, `src/server/register.ts` `registerPart`: one Markdown resource per part, `mcp://bits-and-bolts/parts/<id>`) |
| BLENDED-023 | `elicit_missing?` option (on `tool` and `interface`; default `false`): missing input asked of the user as an MCP form (`AshAi.Tool.Elicitation`) | On `tools/call` of an opted-in tool, after argument transformation and file reconstruction, the action's input is BUILT without running it (`AshAi.Tool.Execution.input_errors/3`: `for_create`/`for_update`/`for_destroy` over an unloaded record/`for_read`/`for_action`, with the call's actor, tenant and context). When there is at least one error and EVERY error is `Changes.Required`, `Query.Required`, `Changes.InvalidArgument`, `Query.InvalidArgument` or `Action.InvalidArgument` naming an input the tool's schema declares (a public argument or accepted attribute, not a file field; an array item's error carries its index as path), and every such input has a form field, the call is answered with a form request instead: `{method, params: {mode: "form", message, requestedSchema}}`, `method` `openai/elicitation/create` when the client advertises `extensions["openai/elicitation"].form`, else `elicitation/create` (client `elicitation` with `form`, or empty). `requestedSchema` is `{type: "object", properties, required?}` over exactly those inputs: `AshAi.OpenApi`'s write type projected onto MCP `PrimitiveSchemaDefinition` (string with `format` email/uri/date/date-time, `minLength`/`maxLength` from `min_length`/`max_length`, and in the OpenAI dialect `pattern` from `match`; integer/number with `minimum`/`maximum`; boolean; `one_of` atoms and `Ash.Type.Enum` as `enum`; an array of those as `{type: array, items: {type: string, enum}}` with `minItems`/`maxItems`), `title` the humanized name, `description` the field's description; `required` the fields a `Required` error names or that do not allow nil; `message` the tool's title and one `field: text` line per error (`AshAi.ToToolError` text with its variables filled in). **2026-07-28 (MRTR):** the result is `{resultType: "input_required", inputRequests: {"missing_input": <request>}, _meta: {serverInfo}}`, no `requestState`; the client calls again with the same arguments and `inputResponses: {"missing_input": <ElicitResult>}`; an `accept`'s `content` is merged into `arguments.input` (over the call's values), validated again — still invalid: asked again with the errors, the answered fields re-asked with their answers as `default` — then the action runs once, as any call. **Initialize-based revisions:** a session whose client declared form elicitation at `initialize` (kept until `DELETE`, `AshAi.Mcp.Elicitations`) and a single `tools/call` on a connection that can stream (not `AshAi.McpActions`' in-memory conn) is answered with an SSE stream: the request as a JSON-RPC request (`id` `ash_ai/elicitation/<uuidv7>`), the client's answer POSTed as a JSON-RPC response (202) feeds the next round exactly as `inputResponses` does, and the call's result closes the stream; no answer within `elicitation_timeout_ms` (server option, default 300000) is a `cancel`, an error answer runs the call as without the option. `decline`/`cancel` answer the call with `isError: true` and `input declined: tool <name> did not run` / `input cancelled: tool <name> did not run` (the action did not run; a non-error result would owe `structuredContent` conforming to `outputSchema`). A client that declares no form elicitation, a tool without the option, a page-view tool and a call whose errors are anything else run exactly as upstream. | MCP 2026-07-28 `InputRequiredResult`/`InputResponseRequestParams`/`ElicitRequestFormParams`/`RequestedSchema` (effect `packages/effect/src/ai/internal/mcpSchema/v2026_07_28.ts` 433–478, 663; `mcpProtocol/v2026_07_28.ts` 104–113, 160–167); MCP 2025-11-25 `StringSchema`/`NumberSchema`/`BooleanSchema`/enum schemas, `RequestedSchema`, `ElicitResult` (`mcpSchema/v2025_11_25.ts` 284–433, 463–481); effect at `6389d9a`; codex (`25270df26`) `scripts/mcp_conformance/server.py` 794–1004 (`input_required` shape, `inputResponses` retry); OpenAI mcp-extensions `docs/spec.md` "OpenAI Form Elicitation" (`openai/elicitation/create`, capability `extensions["openai/elicitation"].form`, extended `pattern`) and codex `rmcp-client/src/elicitation_client_service.rs` 41, 107–112 |

## MCP server output (`AshAi.Mcp.Server`)

- `tools/list` entry: `name`, `title` (from `annotations.title` or the interface/tool name),
  `description` (+ example), `inputSchema`, `outputSchema` (BLENDED-010), `annotations`
  (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`; BLENDED-009), `_meta`
  (upstream free-form map merged with `hyperbob/*` keys).
- `tools/call`: upstream `content` + `structuredContent`, plus the hints text (BLENDED-007), the
  policy breakdown (BLENDED-013), and the forbidden-field rendering (BLENDED-012); for a tool with
  `elicit_missing?`, an `input_required` result (2026-07-28) or an SSE stream carrying an
  `elicitation/create` request (initialize-based) when only input is missing (BLENDED-023).

## Implementation clarifications

Details the table above leaves open, resolved while implementing this branch.

- **BLENDED-001** — a `define` with `get_by`/`get_by_identity` over a read action becomes a
  single-record (`get_by`) tool; over an update/destroy, `get_by_identity` becomes the tool's
  `identity` (ash_hyperlang `surface.ex` `interface_arguments/3`). Interface tools are built by
  `AshAi.Info.interface_tools/1`; `AshAi.Info.action_tools/1` and `exposes/1` split the section.
- **BLENDED-002** — `expose` inside a resource is a compile error. The verifier rejects only name
  collisions that involve an `interface`; duplicate `tool` entries keep upstream's runtime error.
  (`interface` has no Spark `identifier`, because Spark's nested uniqueness check would otherwise
  compare every `tool` in the section by name at compile time.) Non-public actions are skipped.
- **BLENDED-004** — `refine?: false` together with a non-empty `action_parameters` is a compile
  error; `refine?: false` with `action_parameters: []` is accepted. Paginated actions keep their
  page controls either way (as with `action_parameters: []`).
- **BLENDED-005/006** — ported as hyperlang has it: an action that carries `metadata` (every
  create/read/update/destroy) is blocking only through `metadata :blocking?` (default `true` or a
  zero-arity function returning `true`); a generic action is blocking when it or its interface is
  named `:await`. `_meta["hyperbob/blocking"]` and `_meta["hyperbob/continuation_target"]` are
  present only when `true`, so tools without them keep upstream's `_meta` (or none). The
  description gains `Blocking.`, or, when the action has a public `timeout_ms` argument,
  `Blocking. This call waits up to its own timeout_ms, which defaults per action.`; an example is
  appended as `Example:\n<example>`.
- **BLENDED-007** — the hint function receives the raw Ash result and is only called for map
  results (records included); a non-string return, a raise or a throw adds nothing.
- **BLENDED-008** — the callback receives `%{tool:, resource:, action:, arguments:, result:}` and
  applies to every tool on the exposed resource in that domain. Returned maps (`note`, `action`,
  `args`, optional `resource`; atom or string keys) render into `_meta["hyperbob/delivery_hints"]`
  as `%{"tool", "arguments" => %{"input" => args}, "note"}` when an exposed tool matches the
  resource and action/interface name, else as `%{"note"}`, else are dropped. `nil` means none; a
  non-list or raising callback is logged and ignored.
- **BLENDED-009** — Ash only allows `metadata` on create/read/update/destroy actions (checked in
  ash 3.33.6 and ash main `Ash.Resource.Dsl`), so a generic action cannot carry the carrier. The
  carrier is therefore read from any action that declares it and overrides the type default;
  generic actions use the type default unless the tool overrides it. `idempotent?` defaults to
  `false` (the MCP default; the table gives none). `annotations` always carries all four hints;
  `annotations.title` only when set.
- **BLENDED-010** — `outputSchema` is emitted only when every result the tool can return is a JSON
  object, because MCP requires `structuredContent` conforming to it on every call. Read tools that
  offer `count`/`exists`/aggregate results, unpaginated reads (lists), and scalar, array, nullable
  or `returns`-less generic actions get none. Object alternatives (offset or keyset pages) keep
  `"type": "object"` at the root with an `anyOf`. Record properties are never `required` (the
  serializer omits nil, not-loaded and hidden fields) and records are closed
  (`additionalProperties: false`) unless `load` is a function. An `avg` aggregate may be a
  `Decimal` (a JSON string). `AshAi.Tool.Schema.result_for_tool/1` gives the schema of every
  result shape, including non-object ones. **Upstream fix:** the server no longer puts a struct
  (a `Decimal` average, a `Date`) in `structuredContent`; Jason encodes those as JSON strings,
  which MCP does not allow there.
- **BLENDED-011** — the top-level `input` property is required only when some input is required.
  OpenAI strict mode (`strict: true`) still makes every property required, as upstream does.
- **BLENDED-012** — `forbidden_fields` is a `tools` section option on domains and resources:
  resource-level tools use the resource's setting, falling back to the domain's; domain tools and
  interfaces use the domain's; `:hide` is the default. The MCP server option `forbidden_fields:`
  overrides both. `:display` renders `{"opaque": "forbidden"}` (hyperlang's `%{opaque: :forbidden}`),
  in nested records too, and the `outputSchema` property becomes `anyOf [type, marker]`.
- **BLENDED-013** — MCP-only (the server runs tools with `policy_breakdown?: true`); the ReqLLM
  path keeps upstream's `forbidden` text. A denial is a forbidden error carrying policy errors
  (a forbidden error without them keeps upstream's text). The caller gets
  `access denied: tool <tool>, action <action> on resource <Resource> (policy_denied)`; the
  host logs the Ash policy breakdown. With a nil actor, `_meta["mcp/www_authenticate"]` is
  `["Bearer error=\"insufficient_scope\", error_description=\"<text>\""]`, prefixed with
  `resource_metadata="<url>"` when the server has a `resource_metadata_url` option. Tools that
  upstream's permission pre-check already hides stay hidden (`Tool not found`).

- **BLENDED-015** — the stored value is always `{module, opts}` (Spark normalizes the three
  spellings); the MCP server calls `module.hint(result, opts)` and
  `module.delivery_hints(context, opts)`. Everything BLENDED-007/008 say about the function form
  (map results only, string hints only, raise/throw ignored; `nil`, non-list and raising
  callbacks) holds for a module unchanged. An MFA is not accepted, as Spark's
  `spark_function_behaviour` does not accept one.

- **BLENDED-014** — `request` is `%{body, headers, server_url}` (string or atom keys). `body` is
  the JSON-RPC message as `Plug.Parsers` would leave it (decoded JSON), or raw text, which the
  server parses (`-32700` on bad JSON). `headers` maps lower-case names to a string or a list
  (a list keeps a repeated header repeated, so the 2026-07-28 header checks see it);
  `mcp-session-id` is the session id, as `AshAi.Mcp.Router.get_session_id/1` reads it.
  `server_url`, when given, replaces `server_url(conn)`. The response is exactly what the
  server sent: `status`, `headers` (a map) and `body` (the text; the SSE text for
  `subscriptions/listen`; `""` for 202). The HTTP layer stays the host's: routing, the
  `Origin` check (`check_origin/2`), `GET` (405) and `DELETE`, body limits and authentication.
  The conn has no owner, so no `:plug_conn` message reaches the caller's mailbox. The action's
  own policies apply first; `tools/list` is then filtered for the action's actor by upstream's
  permission pre-check. OAuth bearer tokens would be verified by the host, which then invokes
  the action as the token's actor; nothing in the action changes.

- **BLENDED-016/018/019** — `AshAi.Tool.OpenAi` (`lib/ash_ai/tool/open_ai.ex`) holds the
  descriptor rules. `securitySchemes` is not part of `tools/call` results. With strict schemas
  (the ReqLLM path), a nullable file field is `anyOf [<schema>, null]` and every top-level field is
  required, as strict mode does everywhere. When every action argument is a file field, the
  `input` envelope is omitted (BLENDED-011). The reconstruction runs after
  `tool_argument_transformer`. There is no `Ash.Type.File`: file fields are maps the application
  resolves; `context.mcp_files` is caller-supplied request data, never authority.

- **BLENDED-020** — `AshAi.Page` (`lib/ash_ai/page.ex`) holds the rules. BLENDED-021 (server and
  tool icons and title) is withdrawn: those are host metadata, supplied outside the application.
  The page's open tool runs no Ash action of its own: it is the framework's mount (an upsert by
  session) and render. The session digest uses the actor's resource and primary key when the actor
  is an Ash record, the actor term otherwise. Binding tool names are mapped by ash_ai from the
  framework's `{resource, action}`.

- **BLENDED-022** — `AshAi.McpResourceTemplate` (`lib/ash_ai/mcp_resource_template.ex`) holds
  the template rules (`variables/1`, `expand/2`, `match/2`). A variable matches one or more
  unreserved characters or `%XX` escapes (what `expand/2` writes), so a URI with a `/` inside a
  value, an empty value or a malformed escape matches nothing. The listing has no cursor
  (upstream's `resources/list` has none): the list action bounds it (its pagination's default
  limit, a preparation); a page's results are listed. A listing that is forbidden lists no rows;
  any other listing error is logged and lists no rows, so `resources/list` still answers. Each decoded
  value is cast with `Ash.Type.cast_input/3` to its attribute's type (a value that does not cast,
  or casts to nil, names no row); the row read is `Ash.read_one/2` on the `list` action with an
  equality filter per variable. No row or a `Forbidden` error is "Resource not found" (`-32002`;
  `-32602` in 2026-07-28), any other error a read failure (`-32603`), as an action error is. The content action's policies apply as well; the row read is what makes a URI
  readable exactly when the caller's listing would show it, whatever the action does. Row
  entries sort with the static resources by `uri`. With 2026-07-28 the list is cacheable for
  `list_ttl_ms` like the other lists.

- **BLENDED-023** — `AshAi.Tool.Elicitation` holds the rules; `AshAi.Mcp.Elicitations` the
  initialize-based state (a `Registry` of waiting calls and an ETS table of session dialects,
  both under `AshAi.Application`). Nothing is kept for 2026-07-28: the request carries its client's
  capabilities and the answers. The decision is made on the arguments the action would receive
  (after `tool_argument_transformer` and BLENDED-018's reconstruction), and the answers are merged
  before both, as client input. An update or destroy is built over `struct(resource)`, so a
  change that reads the record may raise; a build that raises, an unknown input and an `input`
  that is not an object all run the call as upstream (whose error the caller then gets). An
  argument whose type has no form field (a map, a union, an array of anything but enum strings,
  a struct) makes the call run as upstream. `exclusiveMinimum`/`exclusiveMaximum` (`greater_than`/
  `less_than`) and `format`s MCP does not define (`uuid`, `time`, `byte`, `float`) are dropped:
  the action validates the answer anyway. `pattern` is sent only in the OpenAI dialect, the only
  one whose string schema defines it. The key of the request is `missing_input`. The streaming
  path is chosen per call: an initialize-based call whose tool needs nothing is answered with
  upstream's JSON. A page-view tool (BLENDED-020) is never elicited.

## Tests (the oracle)

Every BLENDED row has ExUnit coverage beside the upstream tests, and all upstream tests still
pass. The Bobstack port's parity rows are these tests plus upstream's.

- `test/ash_ai/blended/dsl_test.exs` — BLENDED-001, 002, 004 (DSL, verifier and transformer errors).
- `test/ash_ai/blended/tools_list_test.exs` — BLENDED-003, 004, 005, 006, 009, 010, 011 (`tools/list`).
- `test/ash_ai/blended/tools_call_test.exs` — BLENDED-007, 008, 011, 012, 013 (`tools/call`).
- `test/ash_ai/blended/output_schema_test.exs` — BLENDED-010: every tool of the test support
  domains (`AshAi.Test.Music`, `AshAi.Test.Blended` in `test/support/blended.ex`) is called for
  every result shape, validating the text content against `result_for_tool/1` and
  `structuredContent` against `outputSchema` with `JsonXema` (already a dependency through
  `ash_json_api`).
- `test/ash_ai/blended/dsl_test.exs` and `tools_call_test.exs` — BLENDED-015 (the three spellings
  of `hints` and `delivery_hints`, the refusals, the behaviours, and the module forms over MCP).
- `test/ash_ai/blended/mcp_action_test.exs` — BLENDED-014: the synthesized action (public,
  argument and return), `initialize`/`tools/list`/`tools/call`/`resources/read`/2026-07-28
  requests through `Ash.run_action/2`, the action's actor reaching tools, tool and action
  policy denials, and the in-memory conn. Support: `test/support/mcp_actions.ex`.
- `test/ash_ai/blended/open_ai_test.exs` — BLENDED-016, 018 (single and array file fields) and
  019. Support: `test/support/open_ai.ex`.
- `test/ash_ai/blended/page_test.exs` — BLENDED-020 (the DSL refusals, listing and the template,
  the generated tools and their schemas, the page in linked and generated tool results, session
  isolation, row bindings, error renders, anonymous refusal). Support: `test/support/page.ex`.
  The end-to-end proof with a real framework is ash_blueprint's Phoenix example
  (`packages/ash_blueprint_phoenix`, `script/serve_mcp_notes.exs`) under the MCP Apps harness.
- `test/ash_ai/blended/row_resources_test.exs` — BLENDED-022 (the verifier's refusals, the URI
  template, `resources/templates/list`, the capability, `resources/list` per caller, and
  `resources/read`: the caller's row only, params, blob, errors, both eras). Support:
  `test/support/row_resources.ex`, whose content actions read the row without authorization, so
  only the server's row read keeps another caller's rows unreadable.
- `test/ash_ai/blended/elicitation_test.exs` — BLENDED-023 (opt-in only, validation before the
  run, only missing/invalid declared input asked, other errors kept, one run after the answers,
  re-asking with errors and defaults, decline/cancel, both dialects, each constraint kind, every
  action type, the initialize-based stream with its POSTed answers, timeouts, error answers,
  `DELETE`, and `AshAi.McpActions`' in-memory conn). Support: `test/support/elicitation.ex`.
- `test/COVERAGE.md` — per-module coverage before and after, and the new-line coverage check.

## Upstreaming

BLENDED-009/010/011 are generic MCP gaps and good upstream PR candidates. If upstream accepts a
different shape, this branch follows upstream and the Bobstack port follows this branch.
