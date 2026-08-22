# Plan: ReyCode-owned tool execution (D22 / D23)

**Scope (confirmed):** ReyCode owns the agent loop and executes tools for **all** providers
(full D20-b harness). The durable `ask` gate ships in the first cut.

## Architecture

Replace the one-directional `Provider.stream/3` (today: provider runs tools, ReyCode only
watches `tool_started`/`tool_completed` frames) with a **two-way contract**:

- The provider yields **tool requests**; it no longer executes tools.
- `ReyCode.Agent` supplies a **controller** to `stream/3` with `emit_frame/1` (existing ETS
  buffering) and `run_tool/1`. `run_tool` dispatches to a new `ToolRegistry`, which enforces the
  trust boundary and emits `:tool_request`/`tool_result` frames.
- Results flow back into the provider (direct provider loops until no more tool calls;
  OpenCode consumes via its permission channel).
- The simulator implements the same contract and becomes the contract test (D22).

## New modules

- `lib/rey_code/tool/behaviour.ex` — `ReyCode.Tool.run(request, ctx) :: {:ok, result} | {:error, ...}`.
- `lib/rey_code/tool/registry.ex` — `ReyCode.ToolRegistry.dispatch/2`; enforces approval model
  (`read/grep/glob/list/edit` allow in roots; `bash`/`write` = `ask` by default; deny outside
  `REYCODE_WORKSPACE_ROOTS`).
- `lib/rey_code/tool/{read,write,edit,bash,grep,glob,list}.ex` — 7 tools. Reuse
  `Security.CanonicalPath.resolve_identity/1`, `Security.Workspace.allowed?/2` +
  `policy_roots/1`, and `Security.Environment.wrap/3` + the `Exile` streaming shape from
  `Provider.OpenCode.Process.open_stream/4` + `collect/4` for `bash`.
- `lib/rey_code/tool/request.ex`, `lib/rey_code/tool/result.ex` — tool request/result structs.
- `lib/rey_code/provider/controller.ex` — the `controller` struct/behaviour (`emit_frame/1`,
  `run_tool/1`) passed into `stream/3`.
- `lib/rey_code/tui/tool_review.ex` — owner review of a pending tool `ask`, mirroring
  `lib/rey_code/tui/gate_review.ex`.

## Changed modules (with anchors)

- `lib/rey_code/provider.ex` — redefine behaviour: `stream(Runtime.t(), Request.t(), controller)
  :: result()`. Add `:tool_request`/`:tool_result` frame kinds to
  `lib/rey_code/provider/frame.ex` (keep `tool_started/tool_completed` handling for v2 replay
  only; stop emitting them).
- `lib/rey_code/agent.ex` — `execute/3` (line 64) builds the controller; `run_tool` path executes
  via `ToolRegistry`, handles `ask` suspension, and reuses the ETS buffer (`enqueue_frame`,
  `flush_frame_buffer`).
- `lib/rey_code/provider/open_code/protocol.ex` — stop emitting `tool_started/tool_completed`
  (lines ~226–259); emit `:tool_request` and defer execution to the controller.
- `lib/rey_code/provider/open_ai_compatible/sse.ex` — same; the adapter loops until no
  `tool_calls` (canonical ReyCode-owned loop).
- `lib/rey_code/provider/simulator.ex` + `lib/rey_code/orchestration/squad/simulator.ex` — inject
  `:tool_request` frames, assert `:tool_result` returned via `run_tool`; extend
  `emit_process: :task` style fixtures (D19).
- **Events** (`lib/rey_code/event.ex`): add `tool_ask_requested` / `tool_ask_resolved` to
  `@types` + `@required_data` (aggregate_type `:invocation`, no schema_version bump).
- **Projector** (`lib/rey_code/orchestration/projector.ex`): add `pending_tool_review` to
  invocation projection; `apply/2` for the two events mirrors `gate_review_requested`/
  `gate_resolved` (lines 383–414) using `invocation` aggregate.
- **Validation** (`lib/rey_code/orchestration/validation.ex`): add `tool_ask_resolution/...`
  mirroring `gate_resolution/4` (line 67).
- **Engine** (`lib/rey_code/orchestration/engine.ex`): add `resolve_tool_ask/...` + `handle_call`
  mirroring `resolve_gate` (line 99/296); expose `ReyCode.resolve_tool_ask/...` in
  `lib/rey_code.ex`.
- **TUI**: wire `tool_review` into `lib/rey_code/tui/slash_palette.ex` + `state.ex` +
  `components/modals.ex`, surfacing pending state like `release_review_status/2`.

## Phases

**P0 — Tool registry + trust boundary (foundation).** Implement 7 tools, registry, approval
model. Unit tests with `Security` fixtures. No provider change yet.

**P1 — Durable `ask` gate.** New events, projector flag, `Engine.resolve_tool_ask`, validation,
`TUI.ToolReview`. Verification: an `ask` tool request pauses the invocation durably (survives
restart via event log) until owner approves/denies; denial fails the invocation. Meets D23
acceptance.

**P2 — Provider contract + Agent loop driver.** Redefine `ReyCode.Provider` with `controller`;
`Agent` owns `run_tool` + frame emission. Both adapters implement the request/response shape.

**P3 — Direct provider owns the loop (showcase) + OpenCode bridge.**
- Direct provider: ReyCode fully drives the loop until no `tool_calls`.
- OpenCode: adapter requests tool execution from ReyCode via the controller. Risk: over stdio
  OpenCode executes its own tools; true ReyCode ownership may require `opencode serve`
  permission-request channel. Document the gap; direct provider + simulator prove the loop.

**P4 — Simulator contract tests + quality.** Property tests for malformed tool requests,
permission denials, `ask` pauses, partial-frame failures. `mix check` + `mix coverage`.

**P5 — Visibility.** Surface resolved `workspace_roots` in `Diagnostics.snapshot/1`.

## Acceptance (per D23/D22)

- Tool registry enforces allow/ask/deny rooted in `REYCODE_WORKSPACE_ROOTS`; deny-by-default
  outside roots.
- An `ask` event pauses the invocation until the owner responds in the TUI — durable and
  replayable like release gates.
- Providers emit tool *requests*; ReyCode executes them through the registry and feeds results
  back inside one invocation.
- Simulator is the contract test for the loop.

## Risks

1. OpenCode tool-deferral over stdio may need serve/permission API.
2. Mid-stream `ask` pause requires ReyCode-owned loop (true for direct provider).
3. Prompt flattening replacement (D22) deferred to follow-up.

## Verification

- `mix check` green; `test/quality/` invariants; `test/property/` tests; simulator contract tests.
