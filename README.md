# ReyCode

ReyCode is a terminal-native coding harness with OMP-style sessions: one
Primary Assistant for ordinary conversation and explicit task agents for
specialized work.

ReyCode owns the agent loop and tool execution itself. Providers stream
responses; ReyCode executes tools through its trusted workspace registry with
durable authorization and owner approval. OpenCode is one provider among
several behind the `ReyCode.Provider` behaviour. A deterministic simulator
remains available for automated FSM, failure-injection, and Monte Carlo
testing. OpenCode credentials remain in OpenCode; ReyCode discovers its
configured models and stores each agent profile's runtime and model selection.

Active decisions and their acceptance criteria are recorded in
[DECISIONS.md](DECISIONS.md).

New to Elixir or this codebase? Start with the [Documentation Index](docs/README.md)
to find the right doc, or jump straight to the
[Architecture Guide](docs/ARCHITECTURE.md) — it walks through the entire
program end-to-end, from keypress to database.

## Install

ReyCode is an Elixir application, so you need the Elixir language and the
Erlang/OTP runtime before you can run anything. **This project requires Elixir
`~> 1.19` and Erlang/OTP 27 or newer** (`mix.exs` pins the constraint; CI
builds against Elixir 1.19.5 on OTP 28.3.1). Check what you have:

```sh
elixir --version   # should report Elixir 1.19.x on Erlang/OTP 27+
```

**macOS (Homebrew):**

```sh
brew install elixir   # the formula installs a matching Erlang/OTP too
```

**Linux:** your distro's `elixir` package is usually years old and won't
satisfy `~> 1.19`. Use a version manager instead — [mise] or [asdf]:

```sh
# mise — install Erlang, then Elixir, then pin both for this directory
mise install erlang@28.3.1
mise install elixir@1.19.5
mise use erlang@28.3.1 elixir@1.19.5

# or with asdf:
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
asdf install erlang 28.3.1
asdf install elixir 1.19.5
asdf local erlang 28.3.1
asdf local elixir 1.19.5
```

Prefer OTP 28.x to match CI. Building Erlang from source needs its development
libraries (`libssl-dev`, `libncurses-dev`, etc. on Debian/Ubuntu). Some
project dependencies (`exqlite`, `exile`) also compile native code, so you
need a C toolchain: Xcode Command Line Tools on macOS, `build-essential` on
Debian/Ubuntu.

First time using Mix (Elixir's build tool)? Install the Hex package manager
to fetch dependencies:

```sh
mix local.hex --force
```

Then verify and start:

```sh
elixir --version
mix deps.get
mix run --no-halt
```

[mise]: https://mise.jdx.dev
[asdf]: https://asdf-vm.com

## Install as `reycode` (macOS / Linux)

Install the latest release — no Elixir, Erlang, or build tools required. The
release bundles its own Erlang runtime and all native extensions:

```sh
curl -fsSL https://raw.githubusercontent.com/Reyane-R/ReyCode/main/install.sh | sh
```

This downloads the release for your OS and architecture (macOS arm64/x86_64,
Linux x86_64/arm64), extracts it to `~/.reycode`, and puts a `reycode` launcher
in `~/.local/bin`. Pin or relocate with environment variables:

```sh
REYCODE_VERSION=v0.1.0 REYCODE_INSTALL_DIR=~/.reycode REYCODE_BIN_DIR=~/.local/bin \
  sh install.sh   # from a repository checkout
```

Typing `reycode` opens the terminal UI. A symlink is not enough here: the
release boot script resolves its own directory, so the launcher must be a real
script. `reycode version` prints the release identity; any other arguments pass
through to the release script (`reycode daemon` runs it in the background).

To build from source instead, run `MIX_ENV=prod mix release` in a checkout and
point the launcher at `_build/prod/rel/rey_code/bin/rey_code`.

The SQLite event store is single-writer: one live instance per data directory.
A second instance against the same store fails closed with `database is
locked`. Quit the first instance with `Ctrl+Q`, or run a throwaway instance in
isolation by launching it under a different `$HOME`.



## Run

```sh
mix deps.get
mix run --no-halt
```

Startup opens a clean session home. No prior transcript is shown. The first
message creates a fresh durable Session with one Primary Assistant.

Task agents are opt-in durable profiles:

1. Run `/agent`, give the agent a name and standing responsibility, then select
   its provider and model.
2. Run `/task`, choose exactly one task agent, and enter a concrete task.

Creating an agent never runs it. Ordinary conversation never invokes task
agents. This allows a Release agent, Test agent, and Documentation agent to use
different models without automatically multiplying token cost.

Each Invocation freezes project instructions before it starts. ReyCode loads
`AGENTS.md` from at most eight Workspace ancestors, root first. Optional
project skills live at `.reycode/skills/<name>/SKILL.md`; enable them explicitly
by listing one safe name per line in `.reycode/skills/enabled`. Sources and
total bytes are bounded, and the durable Invocation records the combined
content digest and exact source paths so restart behavior cannot drift.

- `Enter` or `Ctrl+S`: send the current draft

- `/` or `Ctrl+P`: open a compact command palette; typing searches the full registry
- `/help`: open the deterministic capability reference without invoking a provider
- `/new` or `Ctrl+N`: start a clean Session
- `/resume`: pick and reopen a previous Session
- `/fork`: branch the current Session at its latest durable sequence
- `/rewind <sequence>`: branch the current Session at an earlier durable sequence
- `/tree` or `Ctrl+B`: navigate the durable SessionFork tree; `F` forks the selected node
- `/export`: write a deterministic Markdown Session export inside `.reycode/exports`
- `/advise [brief]`: run an explicit review through the configured Advisor Participant
- `/hub`: inspect and control delegated child Invocations; press `M` on an `awaits merge` child to Apply or Discard its isolated patch
- `/runs` or `Ctrl+O`: inspect durable ToolRun ownership, arguments, authorization, output, and errors
- `/home`: return to the session home
- `/agent`: create a task agent
- `/agents`: change an agent's provider/model
- `/connect`: open provider configuration without model completion
- `/model`: switch the Assistant model in one step
- `/task`: delegate one task to one task agent
- `/answer`: answer the newest waiting OperatorQuestion
- `/artifacts`: inspect and page retained large ToolRun outputs
- `/context`: inspect the latest provider-facing ContextSummary
- `/history` or `Ctrl+R`: search prior Operator prompts and restore one to the composer
- `/hotkeys`: show effective named action bindings and their configuration source
- `/plan`: inspect the newest Invocation WorkPlan
- `/tier`: configure Participant `smol`/`default`/`slow` tiers and future Invocation budgets
- `/steer <correction>`: queue a correction for the active Invocation's next provider-round boundary
- `/retry`: create a new Turn linked to the newest failed terminal Turn
- `/dequeue`: cancel the newest queued FollowUp and return its body to the composer

│
- `!cmd`: run a shell command in the workspace; output lands in the transcript
- `@file` / `#file`: attach a file's content to the next message (workspace
  files only, 512 KB per file, 2 MB total)
- `Tab`: move between the prompt and current transcript
- `Ctrl+A`: open the newest waiting OperatorQuestion
- `Ctrl+B`: open Session Tree
- `Ctrl+O`: open ToolRun Inspector
- `Ctrl+R`: search prompt history
- `Ctrl+G`: configure agent runtimes and models
- `Ctrl+T`: cycle the theme
- `j` / `k`: scroll the focused transcript
- `Ctrl+Q`: exit

Keybindings are named actions resolved at startup from the bounded JSON file
shown by `/hotkeys`. Override its location with
`REYCODE_TUI_KEYBINDINGS_PATH`. A string remaps one chord, an array adds
alternates, and an empty array disables the action:

```json
{
  "app.session.tree": ["M-T", "^B"],
  "app.tools.inspect": "^O",
  "app.quit": []
}
```

Each message shows the work it produced as compact one-line activity blocks.
Executing work uses a shared animated signal and specific verb, for example
`Tool · ⠹ · Reading · lib/foo.ex`, `Running · mix test`, or
`Delegating · Luna`. The animation clock runs only while the selected Session
has executing provider/tool/delegation work. Queued work and owner approval are
truthfully static (`… · Queued`, `Ⅱ · Paused · bash approval required`);
terminal completed/partial/reworked/failed/cancelled Outcomes use stable,
distinct glyphs.

Native agents that surface intermediate reasoning render dimmed activity lines
under the message (`· note`), collapsed behind `+k more activity` when the
trail grows past three lines. Mermaid `flowchart` and `sequenceDiagram` fences
render as bounded ASCII diagrams inside the timeline. The header is the ambient
status line: `ReyCode · model · ⑂ branch · workspace · tok 12.4k/200k`,
followed by the active Invocation tier meter and highest-priority activity in
durable invocation order. A waiting-question badge opens with `Ctrl+A`; the
budget meter and composer warn at 80 percent without stopping the Invocation.

Set `REYCODE_TUI_REDUCED_MOTION=true` in a release environment (or
`tui_reduced_motion: true` in application configuration) to use a static active
glyph and one-second elapsed-time refresh instead of frame animation.

Token usage is summed from durable provider usage records against the
configured `context_budget_tokens` budget
(`REYCODE_CONTEXT_BUDGET_TOKENS`). Before an over-budget Turn starts, ReyCode
records a bounded extractive ContextSummary and a durable ContextBoundary. The
timeline keeps the complete transcript and inserts a visible compaction divider;
`/context` shows the summary sent with later Messages.

Successful ToolRun output larger than 16 KB is retained in the bounded artifact
spool instead of being copied wholesale into the transcript or provider
context. The result includes a preview and `artifact://` identifier. Use
`/artifacts` to inspect retained output; providers can request bounded byte
windows with `artifact_read`. Retention defaults to 128 artifacts and 2 MB per
artifact and is configurable with the `REYCODE_ARTIFACT_*` settings.

OperatorQuestions may present two to five options with descriptions and bounded
previews. `Space` toggles options in a multi-select question, `Enter` submits,
and the Other row accepts bounded text when the question allows it.

Submitting an ordinary message while the Session already has active or queued
work records a durable FollowUp Turn. `/dequeue` cancels only the newest queued
FollowUp and restores its body to the composer; it never cancels executing
work. `/steer <correction>` records bounded Steering on the one active
Invocation. The exact pending Steering IDs are included in the next provider
request and moved into that ProviderRound only when its response is durably
recorded; steering that arrives during a stream therefore forces another round
instead of being lost.

In the command palette, `/` shows common commands plus controls relevant to
current work; typing searches the full registry. Arrow keys move the selection,
Tab accepts the highlighted completion without executing it, Shift+Tab moves
backward, Enter runs it, and Escape returns to the draft. Commands complete
current task Participants, provider/models, Sessions, and immediate workspace
directories. Dynamic arguments are revalidated when submitted. `/cancel` stops
the current task and `/tools` reviews a pending tool approval.

Developer environment tools include structured Git status/diff/review/commit and
conflict-resolution operations, DAP debugger sessions, persistent Python and
JavaScript evaluation kernels, web search, rich URL/PDF/HTML/JSON reading,
project memory, and an opt-in Advisor review. Git commits, conflict resolution,
debugger execution, evaluation, and memory mutation require owner approval.
`/hub` opens the live delegated-child control surface. Wide terminals show a
roster and selected-Invocation inspector together; narrow terminals use `Tab`
to switch panels. `T` toggles flat/tree lineage, `M` reviews a pending patch,
and `C` cancels the selected child. `/advise` queues an explicit review through
the Task Participant named `Advisor` and never enables background review
implicitly.

On macOS, event data is stored transactionally in
`~/Library/Application Support/ReyCode/rey_code.sqlite3`. On first launch, a
legacy `~/.local/share/rey_code/events-v2.ndjson` log is imported and retained
with a `.pre-sqlite-backup` rollback copy.

## Architecture

```text

ReyCode.Application                     rest-for-one dependency supervision
|-- ReyCode.AgentRegistry                unique process registry for Agent workers
|-- ReyCode.EventRegistry                duplicate process registry for subscriptions
|-- ReyCode.EventStore                   transactional SQLite event store
|-- ReyCode.ProviderTaskSupervisor       bounded discovery task supervisor
|-- ReyCode.Provider.Catalog             transient provider discovery and runtime resolution
|-- ReyCode.ProcessHub                   supervised bounded background processes
|-- ReyCode.Orchestration.Supervisor     engine/worker restart boundary
|   |-- DynamicSupervisor                monitored temporary Agent workers
|   `-- ReyCode.Orchestration.Engine     Session commands, FIFO scheduling, admission control
`-- Breeze.Server                        terminal Session client (TUI only)
```

Key logical modules (owning the loop and execution, not separate processes):

- `ReyCode.AgentLoop` — durable provider/tool continuation loop per invocation
- `ReyCode.ToolRegistry` — workspace-trusted tool dispatch and execution

Sessions, Messages, Turns, Invocations, ProviderRounds, ToolRuns, and approvals are
durable. The TUI only dispatches commands and renders projected state.
Providers consume normalized requests and emit sequenced frames; tool
execution is wholly owned by ReyCode.

## Squad workflow

Squad mode is a static, durable FSM supervised by a single squad leader. It uses
one configured seat for each of the twelve roles: Squad Leader, Analyst, Reviewer,
Gherkin Author, QA Author, Implementer, Cleaner, Code Reviewer, Hardener, QA
Tester, Architect, and Senior Implementer.

The fixed 15-phase flow is:

```text
leader_intake
→ stories → story_review → story_gate
→ specification (gherkin + QA plan) → specification_gate
→ implementation → integration → cleanup → code_review → code_gate
→ hardening → qa_validation → architecture_review → release_gate
```

The squad leader automatically approves, requests targeted rework, or aborts at
the story, specification, and code gates. Release-gate authority is frozen at
turn start and is explicit: `--release auto` (the default for headless) keeps
the leader authoritative, while `--release wait` makes the human owner
authoritative. In the TUI, the leader's release-gate decision is always a
recommendation and the human project owner is authoritative: `/release` may
approve, return the work to integration, or abort.

Downstream gate rework repeats from integration through validation. The default
rework budget is three cycles. When the budget is exhausted, the leader cannot
extend it — only the human owner can, by approving another rework at the pending
review. Each owner override recomputes the grant from the current count, so
repeated overrides keep working without a hard ceiling.

Worker artifacts, owner directives, leader recommendations, human release
decisions, provider retries, logical work IDs, and attempts are durable and
replayable. The implementer must return code, unit tests, and acceptance tests
as three separately validated artifacts.

The squad dashboard and directive controls are headless operational surfaces;
they are intentionally absent from the ordinary session TUI.

Run one live squad from the command line. Any provider works — a CLI runtime,
a keyed API profile, or a keyless local one. Use `--workspace` to choose the
project directory; otherwise the current workspace is used. The `--release`
flag selects the release authority (`auto` for leader-authoritative, `wait`
for owner review):

```sh
mix rey_code.squad \
  --provider opencode \
  --model openai/gpt-5.6-sol \
  --workspace "$PWD" \
  --release auto \
  "Implement the requested change"

# Keyed API profile:
mix rey_code.squad \
  --provider deepseek --model deepseek-chat --workspace "$PWD" \
  "Fix the flaky test"

# Keyless local profile (Ollama running on this machine):
mix rey_code.squad \
  --provider ollama --model llama3 --workspace "$PWD" \
  "Summarize the README"
```

Run deterministic Monte Carlo testing without processes or sleeping:

```sh
mix rey_code.squad --runs 10000 --seed 42 --failure-rate 0.02 --jitter-ms 25
```

The test-only simulator injects seeded bounded delays, retryable and permanent failures,
crashes, timeouts, malformed structured output, and failures after partial frames.
Use `--json` for machine-readable summaries.

Each command batch is written as one SQLite transaction. Versioned, checksummed
 projection checkpoints bound startup tail replay; legacy schema-v2 NDJSON import
 ignores an incomplete final record without modifying the preserved source.
 Complete malformed records fail loudly.

## Model auditions (`mix rey_code.eval`)

Create and configure task agents with `/agent` and `/agents`, then run the same
task against an explicit subset without opening the TUI:

```sh
mix rey_code.eval \
  --agent Luna \
  --agent Local \
  --task "Run the focused tests and summarize any failures" \
  --workspace "$PWD"
```

Each `--agent` resolves the most recent exact-named task Participant profile
(for example, Luna on OpenCode or DeepSeek and Local on the keyless Ollama
profile). ReyCode copies only those profiles into a fresh durable Session and
runs independent, blind invocations; the automatically-created Primary
Participant is not auditioned. Missing or unavailable profiles produce their
own error rows while configured candidates continue.

The human report has one row per requested name:

```text
Agent   Outcome    Prompt  Completion  Wall ms  Response
Luna    completed  1842    96          3241     Focused tests passed
Local   failed     -       -           211      Provider is unavailable
```

Use `--json` for the same fields in machine-readable form. The command exits
zero only when every candidate completes; otherwise it prints the complete
report and exits nonzero. `--timeout-ms` bounds the audition (default 600000).
Workspace roots and tool approval are identical to ordinary runs: `bash` and
`write` still need owner approval, so unattended auditions should use
read-only tasks.

## OpenCode and OMP

OpenCode and OMP are CLI providers behind the `ReyCode.Provider` behaviour.
Press `Ctrl+G` or submit `/connect` or `/agents` to configure one agent or every
agent in the current Session. ReyCode reports whether each CLI is
installed, checking, configured, or missing rather than treating process
presence as an online state.

If a CLI has no available models, authenticate in another terminal and press
`R` in the configuration screen:

```sh
opencode auth login
# OMP credentials use OMP's own login/configuration flow.
```

Set explicit executable paths when the CLI is not on `PATH`:

```sh
export REYCODE_OPENCODE_PATH=/path/to/opencode
export REYCODE_OMP_PATH=/path/to/omp
```

Each CLI keeps its own credential store authoritative. API keys are never
copied into ReyCode's append-only event log. The adapters stream one bounded
provider round and retain legacy provider-managed tool execution; ReyCode
continues to own orchestration, durability, and approvals.

## API providers

ReyCode drives OpenAI-compatible chat completion APIs directly — these are
first-class providers, not a fallback. This is where the native agent runtime
lives: each round streams text and usage, returns normalized tool calls, and
ReyCode's own `AgentLoop` executes those requests through its trusted tool
registry, feeds results back into the provider conversation, and keeps every
round durable. Nothing is chat-only; there is no provider-side recursive tool
loop.

DeepSeek ships as a built-in keyed profile. Set its API key in your
environment and it appears alongside OpenCode in `Ctrl+G`:

```sh
export DEEPSEEK_API_KEY=sk-...
```

Ollama and LM Studio ship as built-in **keyless** profiles targeting
`http://localhost:11434/v1` and `http://localhost:1234/v1`. They need no
credential: requests through them never carry an `Authorization` header, not
even an empty bearer token. Start your local server and both appear in
`Ctrl+G`; discovery queries `/models` on the same schedule as every other
provider.

ReyCode reads keys from the environment at invocation time only. They are
never written to the event log, the catalog snapshot, or the diagnostics
report. On first use, the `/models` endpoint is queried once to populate the
model picker; the result is refreshed on the same schedule as OpenCode
discovery and whenever you press `R`.

Add more OpenAI-compatible providers by configuring profiles, each with a base
URL and the environment variable that holds its key (`require_key: false`
makes a profile keyless like the built-in local ones):

```elixir
config :rey_code,
  openai_compatible_providers: [
    %{
      id: :openai,
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      key_env: "OPENAI_API_KEY"
    },
    %{
      id: :vllm_local,
      name: "vLLM",
      base_url: "http://localhost:8000/v1",
      require_key: false
    }
  ]
```

Override any profile's base URL at runtime without changing config:

```sh
export REYCODE_DEEPSEEK_BASE_URL=https://your-proxy.example
```

### Strict servers and capability flags

Some servers reject optional request features with HTTP 400. Profiles carry two
capability flags, both defaulting to `true`: `supports_tools` and
`supports_stream_options`. A strict endpoint can be pinned in profile config or
through the environment without touching files:

```sh
export REYCODE_LMSTUDIO_SUPPORTS_STREAM_OPTIONS=false
export REYCODE_VLLM_LOCAL_SUPPORTS_TOOLS=false
```

Unpinned, ReyCode fails loudly rather than silently degrading: if a server
rejects `stream_options`, the request is retried once without it and the
working shape is remembered for later rounds; if the server then still rejects
the request while tools were offered, the invocation fails non-retryably with
`tool_calls_unsupported`, naming the flag to pin. Dropping tools silently to
degrade into chat-only mode never happens.

Fresh Sessions copy the current Assistant and task-agent runtime assignments.
Sending is blocked only when the addressed agent has no ready runtime. The
ReyCode-owned tool loop is active for all providers with the `:reycode_tools`
capability (OpenAI-compatible and the simulator); OpenCode's stdio adapter uses
the legacy `:provider_managed_tools` capability.

### Tool security model

Providers can request workspace and developer-environment tools — `read`,
`write`, `edit`, `bash`, `grep`, `glob`, `list`, `lsp`, `process`, `git`, `debug`,
`eval`, `memory`, `web_search`, and `read_url`. ReyCode executes them inside
trusted Workspace roots where applicable. Read-only inspection runs after
containment checks. Bash, write, Git mutations, debugger control, evaluation,
and memory mutations require owner approval. Unknown tools fail closed. See
[Tool approval](#tool-approval) for the approval surface.

For editable files within the read byte limit, `read` returns a lowercase
SHA-256 `source_hash`. `edit` requires that hash and one or more unique
replacement patches. It validates every patch against the same snapshot,
rejects stale/ambiguous/overlapping anchors, and commits the complete batch
with one atomic rename. Successful results include both source and result hashes.

Configure a stdio language server with a comma-separated executable/argument
list such as `REYCODE_TOOL_LSP_COMMAND=/path/to/language-server,--stdio`.
The `lsp` tool supports diagnostics, definition, references, hover, symbols,
implementation, code actions, and rename. Every call is bounded and
workspace-contained; rename validates the returned WorkspaceEdit before
applying it.

The `process` tool owns bounded named background processes. `start`, `stop`,
and `restart` require approval; `list`, `logs`, and bounded readiness `wait`
only inspect Hub state. Processes retain only the newest configured output
bytes and are terminated when the supervised Hub stops.

`git` provides bounded status, diff, branch, conflict, review, staged-commit,
and conflict-resolution operations. `debug` drives a configured DAP adapter for
breakpoints, threads, stack frames, scopes, variables, evaluation, stepping,
and controlled execution. `eval` keeps one bounded Python or JavaScript
namespace alive between approved calls.

`web_search` uses an explicitly configured JSON search endpoint. `read_url`
normalizes bounded HTML, JSON, text, and PDF responses when `pdftotext` is
installed. `memory` stores append-only project facts and lessons in SQLite;
`recall` and `reflect` inspect them without mutation.

## Tool approval

Providers can only request workspace tools — `read`, `write`, `edit`, `bash`,
`grep`, `glob`, `list`, `lsp`, `process`, `git`, `debug`, `eval`, `memory`,
`web_search`, and `read_url`. Read-only inspection runs after containment
checks. Bash, write, Git mutations, debugger control, evaluation, and memory
mutations require owner approval. Unknown tools fail closed.

Configure the additional tools with these environment variables:

```sh
REYCODE_TOOL_DEBUGGER_COMMAND=/usr/bin/lldb-dap
REYCODE_TOOL_EVALUATION_PYTHON_COMMAND=python3
REYCODE_TOOL_EVALUATION_JAVASCRIPT_COMMAND=node
REYCODE_WEB_SEARCH_ENDPOINT=https://api.search.brave.com/res/v1/web/search
REYCODE_WEB_SEARCH_KEY_ENV=BRAVE_API_KEY
```

Git inspection is read-only; commits and conflict resolutions are approval
gated. Debugger, evaluation, and memory mutation calls are also approval-gated.
Web search requires an explicitly configured endpoint and key environment
variable; credentials are read at invocation time and never persisted.

When a tool needs approval, a banner appears above the current transcript:

    tool approval required  /  write  /  /tools

Run `/tools` (or click the banner's command) to open the review modal. For
`bash` it shows the exact command, working directory, the names of every
environment variable that will be passed through, and a reminder that Bash is
explicit host execution rather than a sandbox. For `write` it shows the target
path, content size, and a bounded preview. For LSP `rename` it shows the action,
file, new name, and workspace-edit scope. Process mutations show the action,
name, argv, and supervised host scope. Approve with `A`, deny with `D`.

Decisions are addressed to a specific durable tool run ID, so a stale modal can
never approve a different request than the one displayed. Waiting approvals
consume no concurrency slot, survive an engine restart, and denial finishes the
turn as failed without any side effect.

## Agent-initiated delegation

A running assistant can hand bounded subtasks to one of your task agents by
calling the `spawn_task` orchestration tool with an exact participant name and
a self-contained brief:

    spawn_task  {"agent": "Luna", "brief": "Run the focused test suite and report failures"}

The child invocation runs in the same turn with its own durable loop, its own
model resolved through the provider catalog, and the same workspace roots and
approval gates as any other run. The parent pauses — zero further provider
rounds — until the child terminates; the child's structured report (output,
usage) then enters the parent's conversation as the tool result. The timeline
shows the child as its own message under the turn, with a `delegate · <agent>`
row on the parent.

Delegation is depth-bounded: children cannot delegate further (delegation
depth 1), each invocation spawns at most
`delegation_max_children_per_invocation` children (default 8), and briefs are
capped at `delegation_brief_max_bytes` (default 16384). Addressing fails
closed — unknown names and primary participants are rejected without
spawning. Delegation itself is auto-allowed; everything the child executes
still passes the normal tool approval model above. Suspension, restart
recovery (child first, exactly once per side), and cancellation are durable.

`spawn_task` also accepts optional `output_schema`, `isolate`, and `detach` flags.
Structured children are instructed to return only JSON; the frozen schema is
validated before an attached parent ToolRun can complete or a detached Turn can succeed.
`isolate: true` requires a clean git-root Workspace, runs the child in a detached temporary worktree, and
applies the complete bounded binary patch to the source Workspace only after a
successful schema-valid child result. Failed, cancelled, stale, or conflicting
children remove the worktree without applying it.

For parallel work, `spawn_tasks` opens one bounded DelegationWave:

    spawn_tasks  {"shared_context":"Use the public interface","tasks":[{"agent":"Luna","brief":"Run focused tests","output_schema":{"type":"object"}},{"agent":"Nova","brief":"Review the changed contract"}],"integrator":{"agent":"Release","brief":"Integrate the worker reports"}}

Worker children enter admission together and retain their individual
`output_schema`/`isolate` contracts. An optional IntegrationOwner is opened
with dependencies on every worker and starts only after the worker barrier.
The attached parent stays suspended until every Wave child is terminal, then
receives one ordered JSON report containing each outcome and usage record.
Configured global/workspace concurrency still governs actual parallelism;
isolated worktrees count as distinct execution workspaces.

Active Wave children can coordinate durably:

    send_peer  {"target":"Nova","body":"I own the parser; consume parse/1"}

Addressing is exact-name and limited to active siblings from the same Wave.
Bodies and per-sender message counts are bounded. A PeerMessage is included in
the target's next ProviderRound context; `send_peer` does not imply a barrier,
so a recipient that needs the message must keep working until it arrives.
Agent Hub rows show retained peer-message counts.

For work that should not suspend the source assistant, `spawn_task` accepts
`detach: true`. The tool result immediately returns the durable background
Turn and child Invocation IDs. That background Turn owns the normal provider,
approval, schema, worktree, cancellation, recovery, Outcome, and usage
lifecycle without occupying the Session's active Turn slot. Its Task
Participant Message streams into the ordinary transcript and becomes the
durable auto-delivery when terminal.

## Operator questions, WorkPlans, and model tiers

Providers can pause only their own Invocation for a bounded human choice:

    ask_operator  {"question":"Which release path?","options":[{"label":"Safe","description":"Run every gate"},{"label":"Fast","description":"Prefer speed"}],"recommended":0}

The question and its two to five options are durable. `/answer` opens the
waiting question; selecting one option completes the originating ToolRun and
re-arms the Invocation. This is not tool authorization and grants no execution
authority.

Providers maintain visible phased progress with `update_plan`. `init` accepts
ordered phases and unique item names; later actions are `start`, `done`,
`block`, `unblock`, and `drop`. At most one actionable item is in progress.
When none is running, the earliest pending item auto-promotes. `/plan` renders
the newest WorkPlan without changing it.

Each Participant has a ModelTier:

- `smol`: 32,000 provider-reported tokens per Invocation
- `default`: 100,000 tokens
- `slow`: 200,000 tokens

Task Participants default to `smol`; the Primary Participant defaults to
`default`. `/tier` changes the tier for future Invocations. The concrete
provider/model remains the one explicitly configured for that Participant.
Tier and TokenBudget freeze when an Invocation opens. After known cumulative
usage reaches the budget, tools from the recorded round still drain, but the
Engine fails the Invocation before starting another ProviderRound.

## Diagnostics

Inspect production readiness with the doctor task:

```sh
mix rey_code.doctor
mix rey_code.doctor --json
```

The report includes runtime and operating system versions, the resolved data and
database paths with permissions and available space when the platform exposes it,
OpenCode executable/version readiness from the provider catalog, and configured
operational limits. It never includes credential names, environment variables,
model names, event contents, or prompts. The JSON form is intended for support
automation and deployment checks.

## Storage maintenance

Verify the database or create a consistent SQLite backup while ReyCode is stopped:

```sh
mix rey_code.store verify
mix rey_code.store checkpoint
mix rey_code.store backup ~/Backups/rey_code.sqlite3
```

The source database must already exist and be a regular file. These maintenance
commands never create a missing source; a missing source or directory is reported
as an error.

`checkpoint` builds a versioned, checksummed projection checkpoint for an older
database before its replay tail exceeds the configured startup limit.

Restore requires the backup's generated manifest and refuses to overwrite an
existing database unless `--replace` is explicit:

```sh
mix rey_code.store restore ~/Backups/rey_code.sqlite3 --replace
```

## Session export

Export the latest Session, or select one by exact ID, ID prefix, or title:

```sh
mix rey_code.export --format markdown --output session.md
mix rey_code.export --session session-abc --format html --output session.html
```

Exports are deterministic Projection reads. They append no Events and include
the inherited transcript and parent sequence for SessionForks.

## macOS release

Build the unsigned arm64 release archive on Apple Silicon:

```sh
./scripts/build_macos_arm64_release.sh
```

The local release stores its SQLite database under
`~/Library/Application Support/ReyCode` and rotating owner-only logs under
`~/Library/Logs/ReyCode`. Configure trusted workspaces with a comma-separated
`REYCODE_WORKSPACE_ROOTS` value. Public distribution still requires Apple
Developer ID signing and notarization.

## Verify

```sh
mix check
mix coverage
MIX_ENV=dev mix dialyzer
```

`mix check` runs formatting, warning-strict compilation, Credo strict (including
the five custom checks in `credo_checks/`: no `String.to_atom/1`, no
HTTPoison/Tesla/Finch, `:httpc.request` must set a timeout, no bracket access on
structs, and no integer indexing of lists), and the full ExUnit suite. The suite
includes quality guardian tests (`test/quality/`) that fail when production code
violates project invariants, and security-boundary property tests
(`test/property/`) for canonical path resolution, JSON normalization, and
hashing.

`mix coverage` runs the suite once and writes `cover/lcov.info` via ExCoveralls,
failing if total coverage drops below the 75% floor (`coveralls.json`). On pull
requests, CI additionally requires 90% coverage of executable lines changed from
the base branch:

```sh
mix quality.changed_coverage --base "$BASE_SHA" --lcov cover/lcov.info --threshold 90
```

CI also enforces per-function CRAP scores (`CC^2 x (1 - coverage)^3 + CC`),
which keeps clean-code complexity from drifting: functions scoring above 30
must shrink or gain tests, existing offenders may never worsen, and new
offenders fail the build. Legacy offenders are pinned in a committed ratchet
baseline (`quality/crap-baseline.json`):
```sh
MIX_ENV=test mix quality.crap --lcov cover/lcov.info --baseline quality/crap-baseline.json
MIX_ENV=test mix quality.crap --write-baseline   # regenerate after improvements only
```
