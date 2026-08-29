# ReyCode Architecture Guide

This is a guided tour of the ReyCode codebase for someone who doesn't know
Elixir, hasn't built a terminal app, or hasn't touched code in years. It
follows one action — a user typing a message — all the way through the system,
so you can see where the program starts, what every piece does, and why it's
organized this way.

If you want the domain vocabulary (what a "Turn" or "Invocation" means), read
[`CONTEXT.md`](../CONTEXT.md) first. This guide explains the *code*, not the
concepts.

## Before you read: what the program looks like

When you run `mix run --no-halt`, ReyCode starts at a clean session home:

```
┌─────────────────────────────────────────────────────────────┐
│  Welcome to ReyCode                                         │
│  One assistant by default. Task agents run only on demand.  │
│                                                             │
│  Primary assistant                                          │
│  Assistant  ·  <model set via /model>                         │
│                                                             │
│  Quick start                                                 │
│  /agent  create a task agent with its own model              │
│  /model  switch the Assistant model                          │
│  /task   delegate one explicit task                          │
│  !cmd    run a shell command                                 │
│  /new    start another clean session                         │
│                                                             │
│  Task agents                                                 │
│  None yet                                                    │
│                                                             │
│  Recent sessions                                             │
│  None yet                                                    │
├─────────────────────────────────────────────────────────────┤
│  ┌ Ask anything…  / for commands                           ┐ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

The first ordinary message creates a fresh durable Session and invokes only its
Primary Participant. `/agent` creates a durable Task Participant with a
standing responsibility and independently selected provider/model. `/task`
creates a Delegation addressed to exactly one Task Participant. `/resume`
explicitly opens the latest prior Session.


The active transcript shows only useful execution context:

│
- **Header:** `ReyCode · model · ⑂ branch · workspace · tok 12.4k/200k`,
  switching to `thinking · 8s` while a turn runs. Token usage is the durable
  session total against `context_budget_tokens`; the branch is read from
  `.git/HEAD` with no process execution.
- **Timeline:** user messages and addressed responses; assistant messages
  list their tool runs as collapsed one-line blocks (`Tool · read · path ·
  ok`). Tool-run rows are precomputed in `State.session_messages` from
  `invocation.tool_run_order`/`tool_runs`.
- **Composer:** Enter sends. Typing `/` opens the command palette. `@path`
  and `#path` tokens attach a workspace file's content to the message
  (expanded by `ReyCode.TUI.Mentions` before posting — workspace-contained
  paths only, 512 KB per file, 2 MB total; failures surface as a composer
  notice).
- **Focus:** Tab moves directly between prompt and transcript.

`Session` is the sole durable conversation aggregate and the user-facing TUI
concept. Historical Event/SQLite wire fields retain their `room` names only at
the append-only storage compatibility seam.

The TUI is rendered primarily through
`lib/rey_code/tui/components/main_screen.ex`.

---

## 1. What is this program?

ReyCode is a terminal application. A user opens it, sees a clean Session,
types messages, and gets responses from the Primary Assistant or explicitly
addressed task agents. Behind the scenes, it also runs headless for automated
squad workflows.

The program never exits after a single request. It stays running, like a
database or a web server, waiting for input. Elixir calls this an
**OTP application**: a long-running process that manages child processes.

---

## 2. Three Elixir concepts you'll see everywhere

### 2.1. Processes are cheap isolated actors

In Elixir, a "process" is not an operating-system process. It's a lightweight
actor inside the BEAM virtual machine (like a goroutine in Go or a green
thread). You can have hundreds of thousands of them. They don't share memory —
they talk by sending messages.

Every box in the architecture diagram is a process (or a group of processes).
When one crashes, its **supervisor** restarts it. This is how Elixir gets
"let it crash" fault tolerance — you don't write defensive code everywhere, you
let supervisors rebuild clean state.

### 2.2. GenServer is a server in a box

`GenServer` is the most common Elixir process pattern. It's a loop:

```
Wait for message → handle it → update state → wait for next message
```

Callers send messages with `GenServer.call` (synchronous — caller waits for
reply) or `GenServer.cast` (fire-and-forget). The server's state is just a map
or struct that gets replaced on each iteration — no mutation, no locks.

You'll know a module is a GenServer when you see `use GenServer` at the top and
functions named `handle_call`, `handle_cast`, or `handle_info`.

### 2.3. Pattern matching and pipes

Elixir uses `=` for pattern matching, not assignment. It destructures data
and asserts shape at the same time:

```elixir
{:ok, result} = some_function()  # only succeeds if the left side matches the right
```

If `some_function()` returns `{:error, "bad"}`, this line crashes — by design.
Externally-caused failures use `case` or `with` instead of raw `=`.

The `|>` pipe operator feeds the result of one function as the first argument
to the next:

```elixir
state
|> update_session(session_id, fn session -> ... end)
|> put_sequence(event.sequence)
```

This reads as: "start with state, update the session, then put the sequence."

### 2.4. Four patterns you'll see in every file

**Structs.** A struct is a typed map with known fields. Every domain concept
has one:

```elixir
defstruct id: nil, session_id: nil, body: nil, status: nil
```

You access fields with dot syntax: `message.body`. Bracket access
(`message[:body]`) is banned by the coding standard.

**Tagged tuples.** Functions that can fail return `{:ok, value}` or
`{:error, reason}`. Callers pattern-match on the tag:

```elixir
case Engine.post_message(session_id, body, mode) do
  {:ok, turn_id} -> ...
  {:error, :empty_message} -> ...
end
```

**`with/1` chains.** When you need to do several things that can each fail,
`with` stops at the first failure:

```elixir
with {:ok, body} <- Validation.message(raw_body),
     :ok <- Admission.admit_turn(session, state) do
  Lifecycle.queue_message(state, session_id, body, mode)
end
```

If any step returns an `{:error, _}` tuple, `with` returns it immediately.

**`@moduledoc` and `@doc`.** Every module has a `@moduledoc` string at the top
explaining what it does. Every public function has a `@doc` string. Read these
first — they're written to be understood without reading the code.

### 2.5. File naming

Elixir maps file paths to module names mechanically:

```
lib/rey_code/orchestration/engine/turns.ex  →  ReyCode.Orchestration.Engine.Turns
lib/rey_code/agent_loop.ex                   →  ReyCode.AgentLoop
test/agent_loop_lifecycle_test.exs           →  AgentLoopLifecycleTest
```

`.ex` files are compiled. `.exs` files are scripts (tests, config).
Dots in directory names become uppercase letters: `open_ai_compatible.ex` →
`OpenAICompatible`.

To find the file for a module, reverse the process: lowercase everything,
insert underscores before capitals, replace `.` with `/`.

---

## 3. The 5 files you need to read first

Before diving into the six layers, start with these five files. They form the
irreducible skeleton — everything else is a detail:

| File | Why it matters | Time to read |
|---|---|---|
| `lib/rey_code/application.ex` | How the program boots. All 11 processes, in order. | 2 min |
| `lib/rey_code/orchestration/engine.ex` | The central GenServer. Every command enters here. | 5 min |
| `lib/rey_code/orchestration/projector.ex` | How events become state. This is the truth. | 10 min |
| `lib/rey_code/agent_loop.ex` | The durable AI conversation loop. The heart of the program. | 5 min |
| `lib/rey_code/tui.ex` | The terminal UI. How keystrokes become commands. | 5 min |

Open these five side by side and skim the `@moduledoc` and public function
headers. You'll see the program's shape immediately:

```
Boot (application.ex)
  → Engine (engine.ex) receives commands
    → Projector (projector.ex) records state changes as events
      → Agent Loop (agent_loop.ex) runs AI conversations
        → TUI (tui.ex) renders the result
```

---

## 4. How the program starts

Entry point: `lib/rey_code/application.ex` → `ReyCode.Application.start/2`

The Elixir runtime calls `start/2` when you run `mix run --no-halt`. Here's
what happens, in order:

1. **Load configuration.** `RuntimeConfig.load!()` reads all settings from
   the environment and `config/*.exs`, validates them, and freezes them into
   immutable policy structs.

2. **Set up logging.** `ReyCode.Logging.install!()` configures file-based or
   console logging.

3. **Create the data directory.** The SQLite database directory is created if
   it doesn't exist.

4. **Start the supervision tree.** Up to eleven processes start in order (ten headless without `Breeze.Server`; eleven when a TTY is attached). If an earlier one fails, all later ones are stopped (`rest_for_one` strategy):

   ```
   AgentRegistry         A phonebook for Agent processes (unique keys)
   EventRegistry         A phonebook for broadcast subscribers (duplicate keys)
   EventStore            The SQLite database process
   ProviderTaskSupervisor  Runs short-lived discovery tasks
   Provider.Catalog      Discovers what AI models are available
   ProcessHub            Owns bounded named background processes and retained logs
   DebuggerHub           Owns bounded DAP debugger sessions
   EvalHub               Owns persistent Python/JavaScript kernels
   Memory.Store          Owns append-only SQLite project memory
   Orchestration.Supervisor
     ├── DynamicSupervisor  Spawns temporary Agent worker processes
     └── Engine            The brain: sessions, turns, scheduling
   Breeze.Server         Renders the terminal UI (only if a TTY is attached)
   ```

5. **Engine recovery.** The Engine replays any unfinished work from the
   database — turns that were running when the program last stopped get
   their invocations re-queued.

---

## 5. The six layers of the codebase

The program is organized into six layers. Each layer only talks to the one
below it. A change in one layer doesn't ripple through the others.

### Layer 1: TUI (terminal UI)

```
lib/rey_code/tui.ex
lib/rey_code/tui/*.ex
```

The TUI is a thin shell. It owns keyboard shortcuts, focus, and navigation. It
*never* contains business logic. Every user action dispatches a command to the
Engine and waits for a projection update.

ReyCode uses a library called **Breeze** for terminal rendering. `ReyCode.TUI`
implements the `Breeze.View` behaviour: it defines a `render/1` function that
returns HTML-like markup, which Breeze paints to the terminal.

Key files:
- `tui.ex` — Global keybindings and message submission
- `tui/state.ex` — Manages the current Session and drafts
- `tui/render.ex` — Builds terminal markup from the projection
- `tui/slash_palette.ex` — The `/` command menu
- `tui/tool_review.ex` — Approves or denies tool runs
- `tui/settings.ex` — Configures each agent's provider/model

### Layer 2: Engine (orchestration)

```
lib/rey_code/orchestration/engine.ex
lib/rey_code/orchestration/engine/*.ex
```

The Engine is the central GenServer. It owns all durable state: sessions, turns,
invocations, and admission control (how many AI calls run at once). Every
user-facing command goes through the Engine API:

- `Engine.create_blank_session(title, workspace)` → creates a Session
- `Engine.post_message(session_id, body, mode)` → starts a turn
- `Engine.resolve_tool_run(invocation_id, run_id, decision)` → approves/denies a tool
- `Engine.resolve_gate(turn_id, ...)` → resolves a squad gate
- `Engine.cancel_turn(turn_id, reason)` → stops a running turn

The Engine's public API functions (at the top of `engine.ex`) are thin wrappers
that send `GenServer.call` messages. The real work happens in the `handle_call`
clauses, which delegate to focused modules:

| Module | Responsibility |
|---|---|
| `Engine.Sessions` | Create sessions, configure participants |
| `Engine.Turns` | Post messages, cancel turns, resolve gates |
| `Engine.Lifecycle` | Queue messages, start turns, schedule invocations |
| `Engine.Loop` | Tool-loop state machine (rounds, tool runs, frame recording) |
| `Engine.Admission` | Concurrency limits (max 2 global, 1 per workspace) |
| `Engine.Persistence` | Write events, apply to projection, broadcast |

### Layer 3: Event Store (durability)

```
lib/rey_code/event_store.ex
lib/rey_code/event_store/sqlite.ex
```

Every state change in ReyCode is an **event** — an immutable fact written to
SQLite. There is no UPDATE or DELETE of business data. Only INSERT.

An event looks like:

```json
{
  "type": "message_posted",
  "aggregate_type": "room",
  "aggregate_id": "room-abc",
  "data": {"message_id": "msg-1", "body": "Hello"},
  "sequence": 42,
  "recorded_at": "2026-08-23T..."
}
```

`aggregate_type: "room"`, `room_id`, and `room_created` are frozen storage-era
names. The Projector converts them to the Session domain model; normal code
never uses Room vocabulary.

Events are appended in batches per SQLite transaction. The `EventStore` is a
single-writer GenServer — one writer, one sequence — so there are no
distributed consensus problems.

**Projections** are derived read models. The `Projector` module
(`lib/rey_code/orchestration/projector.ex`) is a pure function: given a
projection and an event, it returns a new projection. No side effects, no
database calls. This means any state can be rebuilt from scratch by replaying
events.

**Checkpoints** are snapshots of the projection written every 500 events so
startup doesn't replay the entire history.

### Layer 4: Agent Loop (provider interaction)

```
lib/rey_code/agent_loop.ex
lib/rey_code/agent.ex
```

When the Engine decides an invocation should run, it spawns a temporary
process via the DynamicSupervisor. That process calls `AgentLoop.run/1`.

The Agent Loop follows this cycle:

```
1. Ask the Engine for the invocation's current state (durable request)
2. Drain pending tool runs (execute ready ones, pause on awaiting approval)
3. If all tool runs are done, stream one provider round
4. Record the round (with its tool calls) durably
5. If the round had tool calls → go to step 2
6. If the round had no tool calls → the invocation is done
```

Every step is durable. If the process crashes mid-loop, the next process picks
up exactly where it left off — there is no in-memory-only state.

The Agent (`agent.ex`) handles the mechanics: frame buffering in ETS tables,
error containment, and provider streaming. The Agent Loop (`agent_loop.ex`)
owns the logic.

### Layer 5: Providers (AI model adapters)

```
lib/rey_code/provider.ex              ← behaviour (interface)
lib/rey_code/provider/open_code.ex    ← OpenCode CLI adapter
lib/rey_code/provider/omp.ex          ← OMP RPC CLI adapter
lib/rey_code/provider/open_ai_compatible.ex ← HTTP API adapter
lib/rey_code/provider/simulator.ex    ← Test-only deterministic provider
lib/rey_code/provider/catalog.ex      ← Discovery, readiness, runtime resolution
```

The `Provider` behaviour defines one callback: `stream/3`. Each adapter
implements it:

- **OpenCode** runs the `opencode` CLI as a subprocess, parses its NDJSON
  output, and emits frames. This is the legacy `provider_managed_tools` mode
  — OpenCode executes tools itself.
- **OMP** runs the `omp` CLI in RPC mode, parses JSONL assistant events, and
  emits normalized text frames. OMP executes its own coding-agent tools.
- **OpenAI-compatible** makes HTTP streaming requests to chat completion APIs,
  assembles normalized tool calls from SSE chunks, and returns a `Response`.
- **Simulator** returns deterministic responses for testing. It can inject
  failures, delays, and malformed output.

The **Catalog** (`catalog.ex`) is a GenServer that periodically discovers which
providers are available, what models they offer, and whether they're ready. It
resolves frozen `Runtime` structs for each invocation so the provider sees only
the policy it needs.

### Layer 6: Tool Registry (workspace execution)

```
lib/rey_code/tool_registry.ex
lib/rey_code/tool/*.ex
lib/rey_code/security/*.ex
```

When a provider returns tool calls (e.g., "read file X"), the Agent Loop sends
them to the Tool Registry. The registry:

1. **Classifies each tool** — `read`, `edit`, `grep`, `glob`, and `list` are
   auto-executed. `bash` and `write` require owner approval.
2. **Validates containment** — every file path is resolved to its canonical
   form and checked against the trusted workspace roots.
3. **Dispatches to tool adapters** — each tool gets only its bounded policy
   (e.g., `read` gets a max-byte limit, `bash` gets a timeout and rlimits).
4. **Returns a `Result`** — success with metadata or failure with the reason.

The security layer (`lib/rey_code/security/`) handles canonical path
resolution, workspace containment, and environment allowlisting. Tools never
receive raw user input — they receive validated, bounded requests.

---

## 6. Follow one action end-to-end

Let's trace what happens when a user types "Fix the login bug" and presses
`Ctrl+S`:

### Step 1: Keypress → TUI

`ReyCode.TUI.handle_event("prompt_submitted", ...)` fires. The TUI calls
`submit/2`, which sees no modal is open, trims the draft, checks if it's a
`/` command, and (since it's not) calls `post_message/2`.

### Step 2: TUI → Engine

`Engine.post_message(session_id, "Fix the login bug", :compare)` sends a
synchronous `GenServer.call` to the Engine process.

### Step 3: Engine → Validation → Event Store

`Engine.Turns.post_message/4` validates the message isn't empty, checks that
all session participants have configured providers, and verifies admission
(concurrency limits aren't exceeded). Then it calls
`Lifecycle.queue_message/6`.

This function constructs two event entries:
1. `message_posted` — the user's message itself
2. `turn_queued` — a new Turn for orchestration

It then starts the Turn when admission permits; Turn startup records
`assistant_message_opened` for each Invocation response.

These entries are passed to `Persistence.append_and_apply!/2`, which:
1. Writes them to SQLite in one transaction
2. Runs each event through the `Projector` to update the in-memory projection
3. Creates a checkpoint if we've hit the 500-event interval
4. Broadcasts the new projection snapshot to all subscribers

### Step 4: Engine → TUI (broadcast)

The TUI subscribed to projection updates when it mounted
(`Engine.subscribe/1`). It receives a `{:projection_snapshot, projection}`
message in `handle_info`, which triggers a re-render. The user sees their
message appear in the timeline.

Projection-first terminal surfaces reuse that same snapshot. SessionTree reads
SessionFork parents; ToolRunInspector reads Invocation ToolRuns; AgentHub reads
delegated Invocation lineage; the timeline inserts the latest ContextBoundary
at its durable sequence. These are transient presentations and append no
Events. TurnRetry and Dequeue remain Engine commands because they change
durable Turn state.

### Step 5: Engine → Admission → Agent

`Lifecycle.queue_message/6` calls `start_turn/2` when the Session has no active
Turn, then tries to schedule work. `Admission.pump/1` checks the
concurrency limits and, if there's capacity, spawns an Agent process.

### Step 6: Agent → Agent Loop → Provider

The Agent process calls `AgentLoop.run/1`. The Engine builds an
`InvocationRequest` from the durable session context — all previous messages plus
the current one. The Agent Loop calls `Provider.Catalog.resolve_when_ready/3`
to get a frozen runtime, then calls the provider's `stream/3`.

### Step 7: Provider → API

If the provider is OpenAI-compatible, it makes an HTTP POST to the chat
completions endpoint with the conversation so far. It streams the response,
buffering text chunks and assembling tool calls.

### Step 8: Provider → Agent → Engine (durable round)

The provider returns a `Response` containing text and (optionally) tool calls.
The Agent Loop calls `Engine.Client.record_round/4`, which writes a
`provider_round_recorded` event and one `tool_run_requested` event per tool
call. These are durable before the loop proceeds.

### Step 9: Agent Loop → Tool Registry

For each tool call, the Agent Loop calls `ToolRegistry.dispatch/2`:

- **If `read`/`edit`/`grep`/`glob`/`list`:** the tool executes immediately.
  The result is written as a `tool_run_completed` event.

- **If `bash`/`write`:** the registry returns `{:ask, request}`. The Engine
  writes a `tool_run_requested` event with `authorization: "ask"` and the
  invocation's status becomes `waiting_tool_approval`. The Agent process exits,
  releasing its concurrency slot.

Successful results cross `ArtifactStore.spool/4` before they become provider
wire output. Small output stays inline. Large output is retained under a
bounded count/byte policy, while the ToolRun receives a preview and opaque
`artifact://` identifier. `artifact_read` pages that retained file without
copying it into Events.

### Step 10a: Tool result → Next provider round

If all tool calls auto-executed, the Agent Loop rebuilds the conversation
context from durable state (the assistant response plus tool results) and
calls the provider again. This repeats until the provider returns a response
with no tool calls, at which point the invocation is completed.

### Step 10b: Approval → Resume

If a tool is awaiting approval, a banner appears in the TUI. The owner presses
`A` or `D` in the review modal. This calls
`Engine.resolve_tool_run(invocation_id, run_id, decision)`, which writes a
`tool_run_approval_resolved` event. If approved, the Engine re-enqueues the
invocation, and a new Agent process picks up the loop — it sees the approved
tool run, executes it, records the result, and continues.

### Step 10c: Isolated delegation → Owner merge resolution

When a delegated child with an IsolationWorktree finishes successfully, the
Engine validates its output contract and renders a bounded patch preview.
A non-empty patch records `delegation_merge_requested` and pauses the child;
the source Workspace is still unchanged. AgentHub opens the merge review, and
`Engine.resolve_merge/3` records Apply or Discard before the child and attached
parent may complete. Apply is patch-check/idempotent; both resolutions clean up
the worktree.

### Step 11: Turn completion

When the invocation completes, the Engine's `Loop.complete/3` writes an
`invocation_completed` event. The workflow module's `advance/3` callback checks
whether all invocations are done and, if so, writes a `turn_completed` event.
The TUI re-renders, showing the completed response in the timeline.

---

## 7. Where to find things

```
lib/rey_code/
├── application.ex              ← Boot sequence, supervision tree
├── runtime_config.ex           ← Configuration loading and policy structs
├── runtime_config/             ← Schema, validation, focused policy records
├── logging.ex                  ← Logging setup
├── event.ex                    ← Event type definitions and validation
├── event_store.ex              ← Single-writer SQLite event store
├── event_store/                ← SQLite adapter, NDJSON import, transactions
├── orchestration/
│   ├── engine.ex               ← Central GenServer, public API
│   ├── engine/                 ← Lifecycle, admission, loops, sessions, turns
│   ├── projector.ex            ← Pure event → projection transitions
│   ├── projection.ex           ← Projection struct
│   ├── event_entries.ex        ← Event data constructors
│   ├── context.ex              ← Conversation context for provider requests
│   ├── invocation_request.ex   ← Request data sent to Agent workers
│   ├── session.ex, turn.ex, message.ex, invocation.ex  ← Domain records
│   ├── provider_round.ex, tool_run.ex, tool_runs.ex  ← Loop records
│   ├── squad.ex                ← Squad roster and phase definitions
│   ├── squad_fsm.ex            ← Pure squad state machine
│   ├── workflow.ex             ← Workflow behaviour (compare/debate/squad)
│   ├── supervisor.ex           ← Orchestration supervisor
│   └── squad/                  ← Role, Phase, Seat, gates, dashboard, simulator
├── agent_loop.ex               ← Durable tool loop (the "brain" of an invocation)
├── agent.ex                    ← Agent GenServer, frame buffering, error wrapping
├── provider.ex                 ← Provider behaviour (interface)
├── provider/                   ← OpenCode, OpenAI, simulator, catalog, frames
├── tool_registry.ex            ← Tool dispatch, authorization, execution
├── tool/                       ← read, write, edit, bash, grep, glob, list
├── security/                   ← canonical_path, workspace, environment
├── tui.ex                      ← Terminal UI, named action handlers
├── tui/                        ← State, keybindings, SessionTree, inspectors, modals
├── diagnostics.ex              ← `mix rey_code.doctor` report
├── store_maintenance.ex        ← Database verify/checkpoint/backup/restore
├── retry.ex                    ← Retry policy
├── json.ex, hashing.ex         ← Utilities
└── failure.ex                  ← Typed internal failure records
```

Test files mirror this structure under `test/`:

```
test/
├── orchestration_engine_test.exs       ← Engine integration tests
├── agent_loop_lifecycle_test.exs       ← Agent loop contract tests
├── agent_loop_approval_test.exs        ← Tool approval durability tests
├── tui_test.exs, tui_workflows_test.exs ← TUI integration tests
├── provider/                           ← Provider adapter tests
├── rey_code/tool/                      ← Tool execution tests
├── quality/                            ← Architecture invariant tests
├── property/                           ← Property-based tests
└── support/                            ← Test helpers and wait utilities
```

---

## 8. How to trace a bug

If you're looking at a bug and don't know where to start:

1. **Is it a TUI bug?** (wrong colors, layout, keyboard not working)
   → Look in `lib/rey_code/tui/`. Start with `render.ex` if it's visual,
   `state.ex` if it's navigation state.

2. **Is it a logic bug?** (wrong behavior, incorrect AI response, squad
   phase doesn't advance)
   → Look in `lib/rey_code/orchestration/`. Start with `projector.ex` if state
   is wrong, `engine/lifecycle.ex` if scheduling is wrong,
   `engine/turns.ex` if a command is misbehaving.

3. **Is it a data bug?** (events not persisting, replay is broken)
   → Look in `lib/rey_code/event_store.ex` and `event_store/sqlite.ex`.
   The test `event_store_test.exs` exercises the full append/load/checkpoint
   cycle.

4. **Is it a provider bug?** (AI not responding, wrong tool calls)
   → Look in `lib/rey_code/provider/`. Start with the specific adapter
   (`open_code.ex` or `open_ai_compatible.ex`).

5. **Is it a tool bug?** (read/write/edit/bash behaving wrong)
   → Look in `lib/rey_code/tool/`. Each tool is a single module with a
   `run/2` function.

**The Projector tells you the truth.** If you're ever confused about what
state should exist, read the `Projector.apply/2` clauses for the relevant
event types. The projector is the source of truth for how events become state.

**Every state change is an event.** To understand why something happened,
search the codebase for the event type name (e.g., `:turn_queued`,
`:tool_run_approval_resolved`). The constructor is in `event_entries.ex`, the
projector clause is in `projector.ex`, and the caller is wherever the event
is dispatched (usually in `engine/lifecycle.ex` or `engine/loop.ex`).

---

## 9. Why event sourcing?

You'll notice this program never calls UPDATE or DELETE on business data. Every
change is a new INSERT of an event. This is called **event sourcing**.

A concrete example. When a tool run is approved, here's the difference:

**A typical database would:**

```sql
UPDATE tool_runs SET status = 'ready', resolution = 'approve' WHERE id = 'run-7';
```

The fact that it was ever waiting is lost. If the program crashes after the
UPDATE but before executing the tool, you have a run marked 'ready' that never
ran — and no way to know why.

**ReyCode instead writes:**

```json
{"type": "tool_run_approval_resolved", "data": {"tool_run_id": "run-7", "decision": "approve"}}
```

The `tool_run_requested` event (status: awaiting_approval) still exists. The
`tool_run_approval_resolved` event is appended after it. On restart, replay
tells you: "this run was requested, then approved, but never started — queue it."

The cost is that you have to think in events. But the benefit is that you
never lose data, never have an unrecoverable intermediate state, and can always
answer "how did we get here?" by reading the event log.

---

## 10. Your first change

Let's walk through adding one sentence to the `/status` dashboard. This will
teach you the edit → test → verify cycle.

### 10.1. Find the right file

The dashboard is built in `lib/rey_code/orchestration/squad/dashboard.ex`.
The `data/2` function builds the map that gets rendered. Let's add a
"rework cycles remaining" field.

### 10.2. Read the function

```elixir
def data(session, projection) do
  case turn(session, projection) do
    nil -> nil
    turn ->
      %{
        turn: turn,
        phases: Enum.with_index(Squad.phases()),
        resolutions: Enum.reverse(turn.squad.resolutions),
        ...
      }
  end
end
```

`turn.squad` has `rework_count` and `rework_budget` fields. We'll add
`rework_remaining: turn.squad.rework_budget - turn.squad.rework_count`.

### 10.3. Make the change

Add one line to the map:

```elixir
%{
  turn: turn,
  rework_remaining: turn.squad.rework_budget - turn.squad.rework_count,
  phases: ...
}
```

### 10.4. Run the test

```sh
mix test test/orchestration_squad_dashboard_test.exs
```

If it passes, the dashboard code still works — no existing behavior broke.

### 10.5. Verify in the TUI

```sh
mix run --no-halt
```

Open a squad dashboard with `/status` and confirm the new number appears.

### 10.6. What you learned

- Tests are in `test/` with the same path as `lib/` plus `_test.exs`.
- Run one test file to get fast feedback.
- Always verify UI changes in the real terminal.

---

## 11. How to run one test (not the whole suite)

The full test suite takes a while. When you're working on one area, run just
that file:

```sh
# Engine tests
mix test test/orchestration_engine_test.exs

# Agent loop tests
mix test test/agent_loop_lifecycle_test.exs

# TUI tests
mix test test/tui_test.exs

# Tool tests
mix test test/rey_code/tool/

# A single test by line number
mix test test/orchestration_engine_test.exs:120

# A single test by name (partial match)
mix test test/orchestration_engine_test.exs --only "completes"
```

Before committing, run the full check:

```sh
mix check    # format, compile --warnings-as-errors, credo --strict, test
```

### 11.1. Test structure

Tests use ExUnit. A test file looks like:

```elixir
defmodule ReyCode.EngineTest do
  use ExUnit.Case, async: true   # async: true means no shared state

  test "completes a compare turn" do
    # Arrange
    {:ok, engine} = start_engine()
    {:ok, session_id} = Engine.create_room("test", engine)

    # Act
    {:ok, turn_id} = Engine.post_message(session_id, "hello", :compare, engine)

    # Assert
    assert eventually(fn ->
      %{status: :completed} = Engine.snapshot(engine).turns[turn_id]
    end)
  end
end
```

Tests are in `test/` mirroring `lib/`. Support helpers (like `eventually/1`)
are in `test/support/`.

---

## 12. Reading further

- [`README.md`](README.md) — The documentation index: which doc is for whom.
- [`CONTEXT.md`](../CONTEXT.md) — The domain glossary. Read this when you see
  a term you don't recognize.
- [`DECISIONS.md`](../DECISIONS.md) — Recorded architectural decisions. Read
  this when you wonder *why* something was built a certain way.
- [`Plan.md`](../Plan.md) — The tool execution layer delivery plan. Tells you
  what's done and what remains.
- [`CODING_STANDARD.MD`](../CODING_STANDARD.MD) — Engineering rules. Read this
  before writing code.
- [`docs/standards/TIGER_STYLE.md`](standards/TIGER_STYLE.md) — Bounded
  resources, explicit limits, and safety rules.