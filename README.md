# ReyCode

ReyCode is a terminal-native workspace where project rooms contain humans, agents,
and durable orchestration history. Every message can run as a parallel comparison,
an ordered debate, or an independent fan-out.

ReyCode uses OpenCode as its live agent runtime. A deterministic simulator remains
available only for automated FSM, failure-injection, and Monte Carlo testing.
OpenCode credentials remain in OpenCode; ReyCode discovers its configured models
and stores only each room agent's runtime and model selection.

ReyCode is a personal-first harness becoming **standalone**: ReyCode will own
the agent loop and tool execution itself, with OpenCode remaining one provider
among several during the transition. Shipping real work through the squad
pipeline takes priority over distribution. Active decisions and their
acceptance criteria are recorded in [DECISIONS.md](DECISIONS.md).

## Run

```sh
mix deps.get
mix run --no-halt
```

The default `#reycode` project room contains Builder, Critic, and Explorer.
Each room is rooted at an absolute workspace path shown below the composer. New
rooms preview that path before creation; submit `/workspace` to see it in full.

- `Tab`: move between rooms, timeline, and composer
- `Ctrl+N`: create a project room
- `Ctrl+O`: select compare, debate, or fan-out
- `Ctrl+P`: open the slash command palette
- `Ctrl+S`: send the current draft
- `Ctrl+R`: switch rooms
- `Ctrl+G`: configure agent runtimes and models
- `Ctrl+T`: cycle the theme
- `j` / `k`: scroll a focused timeline
- `Ctrl+Q`: exit

Typing `/` in the composer opens the same command palette. Arrow keys move the
selection, Tab completes it, Enter runs it, and Escape returns to the draft.

Project owners can use `/status` for the squad dashboard, `/direct` to add a
durable directive to a running squad, `/cancel` to stop the active turn after a
confirmation, and `/release` to resolve a pending release gate.

On macOS, event data is stored transactionally in
`~/Library/Application Support/ReyCode/rey_code.sqlite3`. On first launch, a
legacy `~/.local/share/rey_code/events-v2.ndjson` log is imported and retained
with a `.pre-sqlite-backup` rollback copy.

## Architecture

```text
ReyCode.Application                 rest-for-one dependency supervision
|-- ReyCode.EventStore               transactional SQLite event store
|-- ReyCode.Provider.Catalog         bounded runtime/model discovery
|-- ReyCode.Orchestration.Supervisor engine/worker restart boundary
|   |-- ReyCode.AgentSupervisor      monitored temporary provider workers
|   `-- ReyCode.Orchestration.Engine room commands and FIFO turn scheduling
|-- ReyCode.Orchestration.Workflow   compare/debate/fan-out strategies
|-- ReyCode.EventRegistry            live projection subscriptions
`-- Breeze.Server                    terminal room client
```

Rooms, messages, turns, and invocation placeholders are durable. The TUI only
dispatches commands and renders projected state. Providers consume normalized
requests and emit sequenced frames, so OpenCode execution remains separate from
room and workflow semantics.

## Squad workflow

Squad mode is a static, durable FSM supervised by a single squad leader. It uses
one configured seat for each role: analyst, reviewer, Gherkin author, QA author,
implementer, cleaner, code reviewer, hardener, QA tester, architect, and senior
implementer.

The fixed flow is:

```text
theme -> stories -> story review -> leader gate
      -> Gherkin + QA plan -> leader gate
      -> code + unit tests + acceptance tests -> senior integration
      -> cleanup -> code review -> leader gate
      -> hardening -> QA validation -> architecture review -> release gate
```

The squad leader automatically approves, requests targeted rework, or aborts at
the story, specification, and code gates. In the TUI, the leader's release-gate
decision becomes a recommendation and the human project owner is authoritative:
`/release` may approve, return the work to integration, or abort. Headless
`mix rey_code.squad` runs keep the leader-authoritative release behavior so they
do not block waiting for input. Downstream rework repeats cleanup through
validation. The default global rework budget is three cycles. Worker artifacts,
owner directives, leader recommendations, human release decisions, provider
retries, logical work IDs, and attempts are durable and replayable. The
implementer must return code, unit tests, and acceptance tests as three
separately validated artifacts.

The `/status` dashboard shows phase progress, gate history, artifacts, blockers,
retries, owner directives, and aggregated token/cost usage. A `/direct` directive
is included in every subsequently scheduled role's prompt; it does not restart
work already running.

Select it with `Ctrl+O` or `/squad`. Use `Ctrl+G` while squad mode is selected to
assign an OpenCode model independently to all twelve fixed roles. ReyCode blocks a
squad turn until every role has a valid OpenCode model.

Run one live squad from the command line. Use `--workspace` to choose the project
directory; otherwise the default room's workspace is used.

```sh
mix rey_code.squad \
  --provider opencode \
  --model openai/gpt-5.6-sol \
  --workspace "$PWD" \
  "Implement the requested change"
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
still safely truncates only an incomplete final record. Complete malformed
records fail loudly.

## OpenCode

ReyCode prefers OpenCode as its live agent runtime when it is installed. Press
`Ctrl+G` or submit `/connect` or `/models` to configure one agent or every agent
in the current room. ReyCode reports whether OpenCode is installed, checking,
configured, or missing rather than treating process presence as an online state.

If OpenCode has no available models, authenticate in another terminal and press
`R` in the configuration screen:

```sh
opencode auth login
```

OpenCode's own credential store remains authoritative. API keys are never copied
into ReyCode's append-only event log.

## API providers

When OpenCode is not installed, ReyCode can also drive any OpenAI-compatible
chat completion API directly. These providers stream text and usage and can
request workspace tools; ReyCode executes those requests through its trusted
tool registry and feeds results back into the provider conversation.

DeepSeek ships as a built-in profile. Set its API key in your environment and it
appears alongside OpenCode in `Ctrl+G`:

```sh
export DEEPSEEK_API_KEY=sk-...
```

ReyCode reads the key from the environment at invocation time only. It is never
written to the event log, the catalog snapshot, or the diagnostics report. On
first use, the `/models` endpoint is queried once to populate the model picker;
the result is refreshed on the same schedule as OpenCode discovery and whenever
you press `R`.

Add more OpenAI-compatible providers by configuring profiles, each with a base
URL and the environment variable that holds its key:

```elixir
config :rey_code,
  openai_compatible_providers: [
    %{
      id: :openai,
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      key_env: "OPENAI_API_KEY"
    }
  ]
```

Override any profile's base URL at runtime without changing config:

```sh
export REYCODE_DEEPSEEK_BASE_URL=https://your-proxy.example
```

There is no live Demo runtime or automatic simulator fallback. New rooms begin
unconfigured, and sending is blocked until the required runtime assignments are
ready. Historical Demo events remain readable but cannot schedule new work.

OpenCode remains a provider during the transition. Its CLI still owns tool
execution over the current stdio adapter; the ReyCode-owned tool loop is active
for OpenAI-compatible providers and the simulator.

## Tool approval

Providers can only request workspace tools — `read`, `write`, `edit`, `bash`,
`grep`, `glob`, and `list`. ReyCode executes them itself, one durable tool run
at a time, inside the trusted workspace roots. `read`, `grep`, `glob`, `list`,
and `edit` run without prompting; `bash` and `write` always wait for owner
approval first.

When a tool needs approval, a banner appears above the room timeline:

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
