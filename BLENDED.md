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

## Tests (the oracle)

Every BLENDED row has ExUnit coverage beside the upstream tests (`test/ash_ai/blended/*_test.exs`),
and all upstream tests still pass. The Bobstack port's parity rows are these tests plus upstream's.

## Upstreaming

BLENDED-009/010/011 are generic MCP gaps and good upstream PR candidates. If upstream accepts a
different shape, this branch follows upstream and the Bobstack port follows this branch.
