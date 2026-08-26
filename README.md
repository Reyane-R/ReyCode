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

- `Enter` or `Ctrl+S`: send the current draft

- `/` or `Ctrl+P`: open the command palette (fuzzy: `/res` finds `/resume`)
- `/help`: open the deterministic capability reference without invoking a provider
- `/new` or `Ctrl+N`: start a clean Session
- `/resume`: pick and reopen a previous Session
- `/home`: return to the session home
- `/agent`: create a task agent
- `/agents`: change an agent's provider/model
- `/model`: switch the Assistant model in one step
- `/task`: delegate one task to one task agent

│
- `!cmd`: run a shell command in the workspace; output lands in the transcript
- `@file` / `#file`: attach a file's content to the next message (workspace
  files only, 512 KB per file, 2 MB total)
- `Tab`: move between the prompt and current transcript
- `Ctrl+G`: configure agent runtimes and models
- `Ctrl+T`: cycle the theme
- `j` / `k`: scroll the focused transcript
- `Ctrl+Q`: exit

Each message shows the tool runs it produced as compact one-line blocks
(`Tool · read · path · ok`), with the tool, its target, and the run's
outcome. Native agents that surface intermediate reasoning render dimmed
activity lines under the message (`· note`), collapsed behind
`+k more activity` when the trail grows past three lines.
The header is the ambient status line: `ReyCode · model · ⑂ branch ·
workspace · tok 12.4k/200k`, with `thinking · 8s` while a turn runs. Token
usage is summed from durable provider usage records against the configured
`context_budget_tokens` budget (`REYCODE_CONTEXT_BUDGET_TOKENS`).

In the command palette, arrow keys move the selection, Tab completes it, Enter
runs it, and Escape returns to the draft. `/cancel` stops the current task and
`/tools` reviews a pending tool approval.

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
|-- ReyCode.Orchestration.Supervisor     engine/worker restart boundary
|   |-- DynamicSupervisor                monitored temporary Agent workers
|   `-- ReyCode.Orchestration.Engine     room commands, FIFO scheduling, admission control
`-- Breeze.Server                        terminal room client (TUI only)
```

Key logical modules (owning the loop and execution, not separate processes):

- `ReyCode.AgentLoop` — durable provider/tool continuation loop per invocation
- `ReyCode.ToolRegistry` — workspace-trusted tool dispatch and execution

Rooms, messages, turns, invocations, rounds, tool runs, and approvals are
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
mix rey_code.squad --provider deepseek --model deepseek-chat "$PWD" "Fix the flaky test"

# Keyless local profile (Ollama running on this machine):
mix rey_code.squad --provider ollama --model llama3 "$PWD" "Summarize the README"
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

## OpenCode and OMP

OpenCode and OMP are CLI providers behind the `ReyCode.Provider` behaviour.
Press `Ctrl+G` or submit `/connect` or `/models` to configure one agent or
every agent in the current Session. ReyCode reports whether each CLI is
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

Providers can only request workspace tools — `read`, `write`, `edit`, `bash`,
`grep`, `glob`, and `list`. ReyCode executes them itself, one durable tool run
at a time, inside the trusted workspace roots configured via
`REYCODE_WORKSPACE_ROOTS`; paths outside the roots fail closed. Read-only and
edit tools run without prompting after containment checks; `bash` and `write`
always wait for explicit owner approval. Every adapter runs under focused
resource caps — wall-clock timeouts, bounded output sizes, environment
allowlists, CPU-second and open-file limits — declared per tool in
configuration. Unknown tools are denied. See [Tool approval](#tool-approval)
for the approval surface.

## Tool approval

Providers can only request workspace tools — `read`, `write`, `edit`, `bash`,
`grep`, `glob`, and `list`. ReyCode executes them itself, one durable tool run
at a time, inside the trusted workspace roots. `read`, `grep`, `glob`, `list`,
and `edit` run without prompting; `bash` and `write` always wait for owner
approval first. Unknown tools fail closed.

When a tool needs approval, a banner appears above the current transcript:

    tool approval required  /  write  /  /tools

Run `/tools` (or click the banner's command) to open the review modal. For
`bash` it shows the exact command, working directory, the names of every
environment variable that will be passed through, and a reminder that Bash is
explicit host execution rather than a sandbox. For `write` it shows the target
path, content size, and a bounded preview. Approve with `A`, deny with `D`.

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
