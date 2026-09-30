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

Unchanged upstream entities: `tool`, `argument`, `mcp_resources`, `mcp_resource`, `mcp_ui_resource`.

| Id | Addition | Shape | Source |
|---|---|---|---|
| BLENDED-001 | `expose` entity in `tools` (domain level) | `expose Resource do interface :define_name, opts end`. Each `interface` becomes one tool named after the interface, calling the action behind that domain `define`. | ash_hyperlang `domain.ex` `@expose`/`@interface`, `Info.declared_actions/1` |
| BLENDED-002 | Verifier for `expose` | The resource must be in the domain's `resources` block, the interface must match a `define`, and the action must be public (non-public is skipped, as hyperlang does). Tool names stay unique across `tool` and `interface`. | hyperlang `Verifiers.VerifyExposures`; ash_ai `ash_ai.ex` uniqueness |
| BLENDED-003 | `example` option (on `tool` and `interface`) | Worked example string, appended to the tool description. | hyperlang `interface example:` |
| BLENDED-004 | `refine?` option (default true) | `false` omits the read query envelope (filter/sort/limit/offset/result_type). Equivalent to upstream `action_parameters: []`; both are accepted and must agree. | hyperlang `refine?` |
| BLENDED-005 | `blocking?` option | Default comes from the action's own `metadata :blocking?` declaration (or `:await`). An explicit option overrides. Surfaces as `_meta["hyperbob/blocking"]` and in the description. | hyperlang `surface.ex` `blocking?/3`, `blocking_action?/2` |
| BLENDED-006 | `continuation_target?` option (default false) | Marks tools whose calls may park as await continuations. Metadata only. | hyperlang `continuation_target` |
| BLENDED-007 | `hints` option, a `fn result -> String.t() | nil` | Its text is appended as a second text `content` block (model-facing). `structuredContent` is unchanged. | hyperlang `hints`, executor `result_hints_doc` |
| BLENDED-008 | `delivery_hints` entity on `expose` | A per-resource callback returning a list of hint maps, attached to results for that resource. | hyperlang `@delivery_hints` |
| BLENDED-009 | `annotations` option (on `tool` and `interface`) | `title`, `read_only?`, `destructive?`, `idempotent?`, `open_world?`. Defaults from the action type: read → read_only true, destructive false; create → false/false; update/destroy → false/true; generic → from `metadata :read_only?`/`:destructive?` if declared, else read_only false, destructive true. `open_world?` defaults false. | MCP spec `ToolAnnotations`; carrier pattern from hyperlang `blocking?` (action metadata) |
| BLENDED-010 | `output_schema?` option (default true when the result is a map) | Emits MCP `outputSchema` from `Ash.Info.Manifest` (generic `returns`; read/create/update results as the resource's public fields honouring `select`/`load`). It must describe exactly what `structuredContent` returns. | hyperlang documents outputs via `Ash.Info.Manifest` `ActionBuilder` `returns`; MCP spec `outputSchema` |
| BLENDED-011 | Zero-input tools | When no input is required, the input schema requires nothing and `{}` is accepted (ChatGPT entrypoints need this). | hyperlang `Capability.required_arguments?`, arity-0 imports |
| BLENDED-012 | `forbidden_fields` option on the MCP server/`tools` section (`:hide` default, `:display`) | How field-policy-forbidden fields appear in results. `outputSchema` must agree. | hyperlang `eval_actions forbidden_fields` |
| BLENDED-013 | Policy breakdown on forbidden calls | The full Ash policy report is logged host-side; the caller gets a compact `isError` text with the tool name and a stable category. When the actor is nil, add `_meta["mcp/www_authenticate"]`. | hyperlang `EvalActions.PolicyBreakdown`, `GuestError.policy_denial` |

## MCP server output (`AshAi.Mcp.Server`)

- `tools/list` entry: `name`, `title` (from `annotations.title` or the interface/tool name),
  `description` (+ example), `inputSchema`, `outputSchema` (BLENDED-010), `annotations`
  (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`; BLENDED-009), `_meta`
  (upstream free-form map merged with `hyperbob/*` keys).
- `tools/call`: upstream `content` + `structuredContent`, plus the hints text (BLENDED-007), the
  policy breakdown (BLENDED-013), and the forbidden-field rendering (BLENDED-012).

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
- `test/COVERAGE.md` — per-module coverage before and after, and the new-line coverage check.

## Upstreaming

BLENDED-009/010/011 are generic MCP gaps and good upstream PR candidates. If upstream accepts a
different shape, this branch follows upstream and the Bobstack port follows this branch.
