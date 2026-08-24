# Decisions

> **Who this is for.** This is the team's architectural decision log — meeting
> notes, not a tutorial. It uses internal identifiers (D1–D24), PR and issue
> numbers, and assumes familiarity with the codebase. Newcomers: skip this
> file; start with the [Documentation Index](docs/README.md) instead. Read a
> decision here only when you want the recorded *why* behind a specific design.

Accepted 2026-08-20 (Round 1–2 of design review), executed same day where noted.
**Policy** = in effect now. **Planned** = accepted, not yet implemented; do not
claim it in user-facing copy until it ships.

## North Star

ReyCode is a **standalone harness** (D20/D22): terminal-native, personal-first,
with OpenCode's UX feel and omp-grade depth — durable rooms, orchestrated
agents (compare/debate/fan-out/squad), and ReyCode-owned tool execution.
OpenCode remains one provider among several during the transition, not the
runtime. Personal-first scope (D1) still governs sequencing.

## D1 — Personal-first scope (Policy)

Dogfood live squads before any distribution-shaped work. Signing, notarization,
and docs polish stay deferred. `REYCODE_WORKSPACE_ROOTS` stays. **Endgame
confirmed personal-first (Round 4, 2026-08-20).**

Acceptance: the first live squad cycles (D4) complete before any signing or
distribution work starts.

## D2 — OpenCode quarantine (Policy)

All OpenCode knowledge lives behind the `ReyCode.Provider` behaviour — one
provider among several (D24), never the runtime. The simulator doubles as the
provider contract test. `mix rey_code.doctor` records the resolved executable
path and the OpenCode version the adapter was validated against, and launch
fails loudly on stale binaries (D21).

Acceptance: doctor reports resolved path + validated version; provider-specific
shapes do not cross the behaviour boundary.

## D3 — Chat-only providers scoped and frozen (Policy — 2026-08-23)

Chat-only API providers are restricted to compare/debate rooms and can never be
selected for squad mode. The HTTP stack (httpc/SSE) was promoted to the
standalone-harness path per D17 and is now load-bearing: providers stream
normalized tool calls, and ReyCode owns execution through the durable agent
loop. No further feature investment in the HTTP transport layer is planned
beyond bugfixes.

Acceptance: squad configuration statically rejects chat-only runtimes.

## D4 — Static squad FSM until evidence (Policy)

The 12-role, 16-phase squad-v2 FSM stays static until at least three live
squads complete real tasks on real repositories.

Pre-registered change triggers (decided 2026-08-20, before run 1):

- Any manual intervention outside the FSM (forced gate, edited artifact,
  manual re-prompt) in ≥2 of 3 runs → revisit roster/flow.
- Any role whose output is discarded unread in all 3 runs → that phase is a
  token bonfire; cut or merge it.

Acceptance: three completed live squad runs recorded in the event store;
triggers evaluated against them.

## D5 — Unified release authority (Executed 2026-08-20)

Release-gate authority is explicit and frozen at turn start:

- `squad_configured` now carries `release_authority` (`"human"` | `"leader"`),
  derived from the `squad_release_gate_human` runtime flag when the turn starts.
  Flipping the flag mid-turn no longer changes an in-flight squad — verified by
  `orchestration_squad_engine_test.exs` ("release authority is frozen at turn
  start").
- `mix rey_code.squad --release auto|wait` (default `auto` = leader-authoritative,
  preserving headless behavior; `wait` = human review). Invalid values fail
  before any provider work.
- The Finalizer consults the turn's recorded authority (`human_release_review?/1`
  in `engine.ex`), not the global env at finalize time — replays are identical
  regardless of launch interface.
- `workflow_version` bumped to `squad-v3`; v2 events replay with authority
  inferred as the TUI-era default (`"human"`).

Acceptance met: events carry the authority mode; the same run shape replays
identically regardless of launch interface.

## D6a — Durable budget extension (Executed 2026-08-20, folded into D5's pass)

The D6 limitation is resolved: an owner-approved rework at an exhausted budget
now appends a `squad_budget_extended` event (new event type) in the same
transaction as the `gate_resolved` resolution, and the projection's rework
budget updates durably. `SquadFSM.owner_grant/2` remains as the pure-function
computation; the engine persists it. Verified by the updated budget-exhaustion
engine test (final state: rework 4/4).

## D6 — Rework exhaustion escalates (Executed 2026-08-20)

When the rework budget is exhausted with the human gate enabled, the leader's
rework recommendation is owner-reviewed (the existing pending-review surface),
and an owner-approved rework beyond the budget **extends it** instead of
silently failing the turn. The leader cannot extend; the human owner can.

Implementation: `SquadFSM.owner_grant/2` — a `human_owner` rework decision at an
exhausted budget grants `max(budget, count) + 1`, recomputed from the live count
on every resolution, so repeated owner overrides keep working. Headless
(leader-authoritative) behavior is unchanged: exhaustion still aborts.

Known limitation (deferred to D5's schema pass): the grant is recomputed, not
persisted — the projection keeps its original budget (dashboard shows
`4/3`-style overrides rather than rewriting history). A durable
`squad_budget_extended` event belongs with the squad-v3 schema work.

Acceptance met: budget exhaustion produces an owner-visible gate (the leader's
rework recommendation with reasons); resolving it rework never silently fails
the turn. Verified by `orchestration_squad_engine_test.exs` ("owner rework
resolutions keep the squad alive when the budget is exhausted") and
`orchestration_squad_fsm_test.exs`.

Also learned: `ReyCode.Test.Wait` helpers fall back to queued broadcast
snapshots, which go stale across resolves within one test — tests that loop
resolve-and-wait must drain the mailbox first (see `flush_projection_snapshots/0`).

## D7 — Event sourcing stays, replay surfaces (Policy + Planned feature)

The event store stays. The next feature is replay-facing: fork a room from a
turn, or a `/history` replay view.

Acceptance: a replay-consuming feature ships.

## D8 — Rewrite cleanup (Policy; executed 2026-08-20)

The frame-batching/provider rewrite merged to main via PR #39, then PR #40.

Executed: stale branches deleted (local + origin); remote default branch fixed
to `main` (`origin/HEAD` now resolves to `main`); stale plan doc
`.opencode/plans/fix-rewrite-quality-failures.md` removed.

Open item: retrospective justification for frame batching (see D15).

## D9 — TTY probe at boot (Executed 2026-08-23)

Boot probes TTY-ness before Breeze writes anything. Non-TTY contexts get a
one-line actionable error or route to headless squad mode. A crash dump is
never the error message.

Acceptance met: `ReyCode.Application` checks `:io.columns()` and prints
"no terminal detected — starting headless" when no TTY is present; the Breeze
server is not started and no crash dump results.

## D10 — Engine chaos test (Verified existing, 2026-08-20)

Engine-kill recovery is already covered by
`test/orchestration_engine_test.exs` ("recovers an active room turn after the
engine is killed") and squad-phase recovery by
`test/orchestration_squad_engine_test.exs` ("recovers an active squad phase
without duplicating logical work"). No new test required unless live usage
shows a gap.

## D11 — Transcript-grounded simulator (Planned)

Every live squad run captures its OpenCode transcript as a golden fixture. New
simulator scenarios must trace back to an observed failure.

Privacy (D18): fixtures live under the app-data path, gitignored, never
committed; scenarios derived from them use hand-written minimal reproductions,
not verbatim transcripts.

Acceptance: capture is wired before the first live-usage cycle; at least one
scenario derives from a real transcript.

## D12 — Quality apparatus freeze (Policy; trigger recorded)

No new quality tooling until live usage produces a failure the existing
apparatus would not have caught.

**Trigger recorded 2026-08-20:** PR #39 merged with five P1 review findings
open; `mix check` (364 tests, credo --strict, dialyzer) passed all of them.
Corollary merge rule: no merge while unresolved P1 review comments exist.

## D13 — P1 fixes on the OpenCode path (Executed 2026-08-20)

- `agent.ex`: frame buffer moved from the emitting process's dictionary to an
  ETS table owned by the Agent — frames emitted from helper-task processes
  (OpenCode, task-emitting providers) are now durable; previously any response
  under 16 frames recorded zero frames while the invocation reported
  `completed`.
- `agent.ex`: frame-batch persistence errors now fail the invocation instead of
  being discarded.
- `frame.ex`: `validate/1` gains a non-struct fallback returning
  `{:error, :invalid_frame}` — a malformed provider frame can no longer crash
  the central Engine GenServer.
- Regression tests: task-process emission (`emit_process: :task` simulator
  option) and non-frame batch element rejection. `mix check` green: 364 tests,
  14 properties, 0 failures.
- Known flake: `event_store_test.exs` `isolated_start/1` 100ms
  `assert_receive` can fail under full-suite load; passes in isolation.

Not fixed (deliberate): chat-only httpc/SSE P1s (sync request buffering,
charlist transcoding, tool-call fragment keys) — frozen under D3 pending D20.

## D14 — Merge discipline (Policy)

No merge while unresolved P1 review comments exist. Review-bot findings are
triaged to fixed/wontfix-with-reason before merge, not after.

## D15 — Frame-batching admission (Policy)

Frame batching shipped unmeasured: PR #39 names no measurement and marks its
driving issue (#35) partial. Its complexity cost was realized immediately
(process-dictionary frame loss, swallowed persistence errors — see D13). Batching
is retained post-fix (ETS buffer); re-evaluate against a measurement (event-store
append rate, TUI frame latency) at the D4 gate. Re-introducing anything like it
in the future requires a measurement first.

## D16 — First live tasks (Resolved 2026-08-20: Round 4 fallback accepted)

The three D4 tasks, all real work in this repo:

1. **Issue #30** — native agent tool layer (`read`/`write`/`edit`/`bash`/
   `grep`/`glob`/`list`) with containment and caps. P1, unblocked.
2. **Issue #32** — native multi-step agent loop for API providers (blocked by
   #30, #31, #35, #36 — sequence accordingly).
3. **S1 trust core** (D9, D5, D6, D21) — ReyCode's own stability, run through
   the squad pipeline per D22's parallel plan.

D4's pre-registered triggers apply to these runs.

## D17 — Chat-only provider disposition (Resolved 2026-08-20: promoted)

The OpenAI-compatible HTTP stack (httpc/SSE/profiles) is the foundation of the
standalone-harness path (D22): direct provider access with ReyCode-owned tool
execution. Un-frozen. Its three open P1s (sync response buffering, charlist
transcoding, tool-call fragment reassembly) become load-bearing bugs on the
critical path once the direct provider is primary and must be fixed then —
streaming is not optional for a harness that executes tools mid-generation.

## D18 — Fixture privacy (Policy)

Golden transcripts and fixtures are local-only, gitignored, never committed.
Scenarios derived from them are hand-written minimal reproductions.

## D19 — Simulator fidelity (Planned)

`emit_process: :task` (added 2026-08-20) lets the simulator mirror the OpenCode
task-process emission topology; new cross-process scenarios should use it.
Remaining: golden-fixture capture pipeline (D11).

## D20 — North-Star fork (RESOLVED 2026-08-20: standalone harness)

**Decision: (b) — ReyCode is a standalone harness, not a wrapper.** ReyCode owns
the agent loop and tool execution; providers stream; OpenCode stops being the
runtime and becomes at most one provider among several. The protocol audit
below is retained as evidence for what the OpenCode adapter can still offer as
a provider (sessions, personas, observability) and what it cannot (steering).

Paths considered:

Paths to "OpenCode UX × omp capability":

- **(a-stdio) Control plane over `opencode run`**: current transport.
- **(a-serve) Control plane over `opencode serve`**: same architecture, HTTP
  transport with steering.
- **(b) Full harness**: ReyCode owns the agent loop and tools; OpenCode becomes
  one provider or is dropped.

Protocol audit (verified locally against OpenCode 1.18.19 unless noted):

- Sessions exist and resume: `-s <id>` / `-c` verified working; every NDJSON
  record carries `sessionID`. ReyCode parses it (`session_started` frame,
  `finish/0` returns `session_id`) but never feeds it back — `prompt.ex`
  re-flattens the entire conversation into each stdin prompt instead.
- Tool events are fully observable inline: tool name, args, output, exit code.
  ReyCode's frames keep only tool+state and drop input/output/exit detail.
- `--agent <name>` personas accepted per invocation; custom agents are markdown
  files (`~/.config/opencode/agents/` or `.opencode/agents/`) with per-tool
  permission maps (allow/ask/deny), model, prompt, mode, max steps.
- The hard ceiling of stdio: no mid-run steering. No abort, no redirect, no
  orchestrator-mediated permission approval (`--auto` is blanket approval).
  Stream is append-only records, not a control channel.
- Steering exists only behind `opencode serve` HTTP: `prompt_async`, `abort`,
  `POST /session/:id/message` accepts a per-call `tools` list,
  `permissions/:permissionID` responds to permission requests mid-run,
  `/global/event` SSE, config GET/PATCH, MCP add. Documented with OpenAPI spec
  and SDK. ACP (stdio JSON) also exists, less documented.

Verdict: (a) has significantly more headroom than the current adapter exploits
(sessions, personas, tool detail, `--attach` warm server). The omp-grade
features — orchestrator-gated tool approval, abort, per-message tool scoping —
are reachable via (a-serve) without building an execution plane. (b) is only
forced if OpenCode itself becomes the constraint.

## D21 — OpenCode binary drift hazard (Executed 2026-08-23)

The `ReyCode.Provider.Runtime` module now fingerprints each OpenCode executable
via `identify_executable/1` (canonical path, device, inode, sha256) and
`revalidate_executable/1` detects drift before launch. The Catalog's snapshot
records the resolved executable path and identity. The doctor reports the
resolved path and validated version.

## D22 — Standalone execution (Executed 2026-08-23)

ReyCode owns execution. Concretely:

- Providers emit tool **requests**; ReyCode executes them against the workspace
  through `ReyCode.ToolRegistry` (seven tools: read, write, edit, bash, grep,
  glob, list) and feeds results back into the conversation loop inside one
  invocation.
- `ReyCode.AgentLoop` owns the tool-loop driver; `ReyCode.Provider` behaviour
  carries the request/response tool protocol; the simulator is the contract
  test for the loop.
- The security layer (`canonical_path`, `workspace` roots, `environment`
  allowlist, rlimits) is the tool-execution trust boundary.
- Everything above the provider seam survives unchanged: rooms, turns,
  invocation lifecycle, retries, squad FSM, event store, projector, TUI.

Delivered across five implementation batches (see [Plan.md](Plan.md)):
  1. Simulator plus durable safe-tool loop
  2. Durable approval, denial, recovery, and admission
  3. OpenAI-compatible adapter hardening
  4. Tool security and bounded execution semantics
  5. TUI, migration, diagnostics, and documentation

## D23 — Tool layer v1 scope (Resolved 2026-08-20: Round 4)

**v1 tools:** per issue #30 — `read`, `write`, `edit`, `bash`, `grep`, `glob`,
`list`. The issue (authored 2026-08-16, with resolved design decisions on
failure semantics, edit ambiguity, bash result shape, and caps) is the spec;
do not fork it here.

**Approval model (this decision supersedes #30's "tools auto-execute" note —
update the issue when implementing):** per-tool allow/ask/deny rooted in
workspace trust. Deny-by-default outside `REYCODE_WORKSPACE_ROOTS`; `ask`
initially for `bash` and `write`, surfacing in the TUI via the existing
gate-review pattern; `read`/`grep`/`glob`/`list`/`edit` allowed inside trusted
roots.

Acceptance: the tool registry enforces the policy; an `ask` event pauses the
invocation until the owner responds in the TUI (durable, like release gates).

**Amendment (2026-08-23): Bash is approved host execution.** Bash runs with a
minimal allowlisted environment, rlimits, byte-capped captured output, and a
process-tree teardown on timeout, but it is not filesystem-sandboxed to the
workspace: it can read and write anywhere the host user can. Every Bash run
therefore shows the exact command, working directory, environment names, and
execution scope for owner approval before it starts — the approval IS the
boundary, matching D22's ownership guarantees rather than pretending to a
sandbox that does not exist.

**Amendment (2026-08-23): durable tool-run semantics supersede tool_ask
events.** Approvals are recorded as `tool_run_approval_resolved` against a
specific ToolRun ID; at most one owner review is active per invocation;
waiting consumes no admission slot; recovery reuses completed results, fails
running runs as indeterminate, and keeps awaiting runs dormant. The legacy
`tool_ask_*` event types are retained for replay only.

## D24 — OpenCode demoted, not deleted (Policy — 2026-08-20)

The OpenCode adapter stays as one provider behind the `ReyCode.Provider` seam:
it works today, gives a functioning squad path while the standalone loop is
built, and D21's version pinning keeps it honest. Revisit removal only after
the tool loop runs a squad end-to-end on direct providers.
