# ReyCode

ReyCode is a standalone terminal coding harness with one
Primary Assistant for ordinary conversation and explicit task agents for
specialized work.

## Why ReyCode

ReyCode connects directly to hosted or local model APIs and owns the complete
coding loop: conversation context, model requests, tool execution, owner
approvals, delegation, and durable history. A deterministic simulator backs
automated workflow and failure-injection tests. Sessions and recorded decisions
survive restarts, and optional squad workflows add explicit release gates.

No OMP or OpenCode installation is required. Models return text and tool
requests; ReyCode authorizes and executes those requests itself.

Active decisions and their acceptance criteria are recorded in
[DECISIONS.md](DECISIONS.md).

New to Elixir or this codebase? Start with the [Documentation Index](docs/README.md)
to find the right doc, or jump straight to the
[Architecture Guide](docs/ARCHITECTURE.md) — it walks through the entire
program end-to-end, from keypress to database.


## Quickstart

```sh
mix deps.get && mix run --no-halt
```

Opens a clean session in your terminal. Then:

- `/agent` — create a task agent with its own provider and model
- `/task` — delegate one task to that agent

That's the whole loop. Squad workflows, project memory, and release gating are
opt-in. The [Run](#run) section lists every command; [Install](#install) covers
release builds and updates.

## Install

ReyCode is an Elixir application, so you need the Elixir language and the
Erlang/OTP runtime before you can run anything. **This project requires Elixir
`~> 1.19` and Erlang/OTP 27 or newer** (`mix.exs` pins the Elixir constraint; Erlang/OTP 27+ is a runtime requirement, not a code pin. CI
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
in `~/.local/bin`. An update replaces an idle shared engine before switching the
launcher. It refuses to interrupt active work; wait for completion or stop the
engine explicitly. A legacy engine that cannot report readiness is stopped only
by this explicit update path, which can interrupt its work. Pin or relocate with
environment variables:

```sh
REYCODE_VERSION=v0.2.4 REYCODE_INSTALL_DIR=~/.reycode REYCODE_BIN_DIR=~/.local/bin \
  sh install.sh   # from a repository checkout
```

Typing `reycode` opens the terminal UI for the current directory. A symlink is
not enough here: the release boot script resolves its own directory, so the
launcher must be a real script. `reycode version` prints the release identity;
any other arguments pass through to the release script (`reycode daemon` runs
it in the background).

To build from source instead, run `MIX_ENV=prod mix release` in a checkout and
point the launcher at `_build/prod/rel/rey_code/bin/rey_code`.

### Multiple terminals and workspaces

Run `reycode` in several terminals, including in different project directories.
Each terminal attaches to one shared local engine for its data directory. The
first launch starts the engine automatically; the database remains single-writer.
Each terminal selects its own canonical launch directory and keeps its own draft,
scroll position, and panels. Its first new conversation is independent; explicitly
resume a conversation to share live updates with another terminal.

Tools use their Session's workspace, not the engine's startup directory. Named
background processes, debugger sessions, and evaluation kernels are scoped by
workspace and Session, so two projects can both use a resource named `server`.
Workspace memory and durable history remain shared through the engine.

`Ctrl+Q` or `/quit` closes only that terminal. Work continues in the engine.
Lifecycle controls are explicit:

```sh
reycode engine status
reycode engine stop   # stops the shared engine and can interrupt active work
# Source-checkout equivalents:
mix rey_code.engine status
mix rey_code.engine stop
```

Between polls, an attached terminal receives only the events appended since
its last sequence and projects them locally with the engine's own projector;
a terminal further behind than the engine's bounded recent-event ring receives
a whole snapshot instead. Clients reconnect with a fresh snapshot after a
connection loss. Unacknowledged commands are never automatically replayed:
inspect history before retrying them.
All clients must match the engine's protocol, exact code build, storage path,
and engine settings. A new build, or a changed engine configuration such as a
different shell environment, automatically replaces an idle compatible engine
after closing new-work admission. Active work, protocol, and storage mismatches,
and unverifiable legacy engines, fail with a normal diagnostic instead of a VM
crash; stop those engines explicitly when interruption is safe. Terminal display
settings remain client-local. Install updates retain immutable runtime
directories under `~/.reycode/builds`, so active engines do not lose their
files; old builds may be removed after their engines have stopped.

The first transition from an older standalone release requires quitting that
old instance once. It cannot accept shared-engine connections. New releases do
not bypass its database lock or terminate it automatically.

`REYCODE_DATA_DIR` selects a separate engine/history when isolation is desired
and is honored by source and release launches. Memory and artifacts follow that
directory too. `REYCODE_ENGINE_ROLE=standalone` retains the single-process mode
for tests and maintenance; it requires exclusive database ownership. The shared
engine currently supports macOS/Linux Unix sockets, up to 32 attached clients,
64 concurrent IPC operations, and 128 scoped resource hubs. Idle, unborrowed
hubs can be reclaimed at capacity. These are local ownership boundaries, not
an OS sandbox or a multi-user remote service.

### Herdr integration

When `reycode` runs inside a Herdr pane, it reports `working`, `blocked`, and
`idle` lifecycle state to Herdr's custom-agent API. Herdr must provide
`HERDR_ENV=1` and `HERDR_PANE_ID`; `HERDR_BIN_PATH` is used when present, or
the `herdr` executable is resolved from `PATH`. Reports are inert outside a
Herdr pane and do not affect ReyCode execution.

## Updates

Release builds check GitHub for a newer published release once at startup —
one bounded request, never from source checkouts, disable with
`REYCODE_TUI_UPDATE_CHECK=false`. When a newer release exists, the welcome
screen and session header show "Update available: 0.2.3 → 0.2.4 — run `reycode update`".

`reycode update` re-runs the installer for the latest release and replaces
`~/.reycode` in place; pin a version by exporting `REYCODE_VERSION` first.
Sessions keep their durable event store across updates — data lives in the
platform data directory, never inside the install.

To ship an update: bump `version` in `mix.exs`, commit, then
`git tag vX.Y.Z && git push origin vX.Y.Z`. CI builds all four platforms and
publishes the release; users see the notice on their next session start.



## Run

```sh
mix deps.get
mix run --no-halt
```

For one bounded, non-interactive Turn, use the installed launcher or its source
equivalent:

```sh
reycode run -p "Summarize the failing tests"
printf '%s\n' "Name the riskiest module" | reycode run --json
mix rey_code.run --workspace "$PWD" "Review this Workspace"
```

One-shot mode creates a fresh durable Session, reuses the latest Primary
Assistant runtime assignment, and prints only the response (or a JSON report).
It cancels the Turn and exits nonzero instead of waiting when a tool approval
or OperatorQuestion needs an interactive owner. `--timeout-ms` defaults to 600000.### Verified changes (opt-in)

Use a clean Git repository root with a configured Primary Assistant profile to
request one isolated change with harness-owned checks:

**In the terminal UI**, run `/verify` or `/verify <goal>`. Enter the goal and
one check command per line. Tab moves from Goal to Checks to **Authorize checks
and start**; only selecting that action starts execution. The setup screen
discloses host execution and the default limits: ten minutes total, two minutes
per check (also subject to Bash policy), and one repair. The new Session copies
the Primary Assistant from the Session that initiated it.

You can leave the screen or navigate to another Session without cancelling the
work. The header shows the current phase, baseline/current check counts, repair
usage, and whether an answer or approval is needed. `/tools` and `/answer` resume
the same waiting work after your decision; they do not start a fresh attempt.
The total deadline includes decision waits. `/cancel` stops the entire verified
change, including checks running without an active conversation Turn. Already
executing host operations drain under their bounded timeouts and cleanup before
ReyCode releases the execution barrier; a blocked result alone is not evidence
that host work has stopped.

**For non-interactive use**, the CLI remains available:

```sh
reycode run --verified \
  --check "mix test test/session_recovery_test.exs" \
  --check "mix check" \
  --max-repair-count 1 \
  --json \
  "Fix session recovery and preserve existing history"

# Source checkout equivalent:
mix rey_code.run --verified --check "mix check" "Fix the reported bug"
```

The named checks must be valid for your repository. ReyCode freezes the goal,
ordered commands, starting commit, and limits; runs a baseline in a detached
worktree; then runs the Primary Assistant and the same checks. Ordinary baseline
failures remain context. Failed final checks admit only the configured number of
repair Turns in the same Session. The complete contract is included outside
compactable history in every model request. An oversized contract fails with an
explicit context-budget error rather than losing its goal.

### Multi-model workflow (opt-in)

Verified changes can hand routine work to cheaper models. The optional
`--testing-provider`/`--testing-model` and `--release-provider`/`--release-model`
pairs freeze report-only stage runtimes before the run starts:

```sh
reycode run --verified \
  --check "mix test test/session_recovery_test.exs" \
  --max-repair-count 1 \
  --testing-provider deepseek --testing-model deepseek-chat \
  --release-provider ollama --release-model llama3 \
  --json \
  "Fix session recovery and preserve existing history"
```

- **Main** (the Primary Assistant) implements and performs every repair.
- **Testing** sees the immutable failed-check evidence after a failed final
  check and returns a bounded advisory report that Main's repair prompt
  includes. If the stage fails or times out, the report records
  `outcome: unavailable` and repair proceeds on the raw check evidence.
- **Release** drafts commit subject/body and PR title/body after checks pass.
  The draft is stored in the retained evidence (`metadata`); readiness never
  depends on it, and nothing is committed or pushed automatically.

Stage workers run with zero tools: they cannot edit files, run commands, or
delegate. Failed checks are decided by exit codes alone — a stage can never
turn a failure into a pass. Unresolvable stage providers fail the change
closed before any check runs. Every stage report is retained with its Turn ID
in the JSON report and Session exports.

**`--check` authorizes host shell execution**, including repository scripts and
any side effects they perform. A worktree is edit isolation, not an OS sandbox.
The Bash environment allowlist is honored and its values are frozen for the
run, not persisted as configuration. Do not place credentials in prompts,
commands, or check output. The assistant itself cannot run shell, Git, network,
debugger, LSP, background-process, memory, or delegation tools in this mode.
Its file tools are confined to the isolated worktree. Git metadata, ignore and
attribute rules, ignored untracked files, and hardlinked mutation targets are
protected. Creating files with `write` follows configured tool permissions. Interactive
verification waits for you; the headless command cancels and reports `blocked`
when approval or an operator answer is needed. Neither surface automatically
grants broader permission. Restart does not resume an interrupted coordinator.

`ready` means every final command exited zero against the retained candidate
snapshot, and the source was still at its clean starting revision. It does not
mean the patch was applied, accepted, independently graded, or proved correct
for every requirement. Check-induced candidate changes, source changes,
timeouts, capture failures, exhausted repairs, and interrupted runs cannot
produce `ready`. Restart records unfinished verified changes as `blocked`
without replaying their tools.

JSON output includes the full retained binary Git patch, its base-bound SHA-256
digest, baseline/final results, and Session/worktree identifiers. Human output
shows authoritative verification details separately from the assistant's
response. Both success and failure retain the worktree for inspection; ReyCode
never automatically applies it to the source. The durable patch and evidence
also appear in Session Markdown/HTML exports:

```sh
mix rey_code.export --session SESSION_ID --output verification.md
# After inspection and after all execution has stopped:
git -C SOURCE_WORKSPACE worktree remove --force ISOLATED_WORKSPACE
```

Use the actual identifiers and paths from the report. Removing the worktree
does not remove its retained evidence. Do not regenerate a patch from a
subsequently modified worktree and assume the previous verification still applies.

**Review in the terminal with `/changes`.** Keys `1`-`4` switch between Summary,
Files, Patch, and Checks; arrows and PageUp/PageDown scroll, `n`/`p` move between
files, and `]`/`[` move between hunks. No decision is selected when review opens.
`a` selects Apply, `d` selects Discard, and Enter confirms the selection.
Apply consumes the exact retained patch, not current worktree contents, and
requires the source to remain at the original clean revision. Discard retains
both evidence and the worktree; it does not delete files implicitly.

`Applied` is a separate durable resolution, not a replacement for `Ready`.
Checks describe the isolated candidate and are **not rerun after integration**.
While application is pending or uncertain, ReyCode conservatively blocks new
Turns and owner commands across Sessions because tool roots can overlap. Apply
also waits for live, queued, approval-paused, and draining execution to finish.
Independently authorized background processes and external writers are not
sandboxed or transactionally locked by this barrier.

Interrupted application becomes `Indeterminate`, never an automatic retry.
Select `r` then Enter to reconcile: ReyCode compares the actual source snapshot
with the retained patch and its starting revision. Unknown or partial state
remains uncertain. To request another change, `e` opens a new editable goal and
the same checks. Authorization starts a **fresh candidate from the current clean
source**, with the same Primary profile; it does not reuse or mutate the old patch.

Limits: 1-8 check commands of at most 4096 bytes each; 0-3 repairs (default 1);
total timeout at most one hour (default 10 minutes); per-check timeout at most
10 minutes (default 2 minutes, also capped by the configured Bash timeout).
Command termination/reaping has the Bash adapter's additional bounded grace.
Capture is capped at 1 MiB per stream; overflow blocks. Durable output previews
are capped at 16 KiB and explicitly marked when shortened. The candidate is
limited to 10,000 files, 128 MiB of file bytes, and a 2 MiB patch. Ignored files
and empty directories are outside the Git snapshot; repositories using Git
attributes or submodules are rejected by this initial implementation. Verified
prompts are capped at 40,000 bytes, with a 70,000-byte encoded goal/commands cap.

Startup opens a clean session home scoped to the canonical current directory.
ReyCode reuses the newest Session from that Workspace as the source profile; if
the Workspace has no Session, it creates one blank source Session there. It
never selects a Session from another Workspace during automatic startup.
`/resume` remains the explicit path for opening prior Sessions. On a pristine
unconfigured source Session, ReyCode opens guided Primary Assistant provider and
model selection; `R` rechecks provider discovery. No prior transcript is shown,
and the first message creates a fresh durable Session with one Primary Assistant.

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
- `Shift+Enter` or `Ctrl+J`: insert a newline
- `↑` / `↓`: recall prior Operator prompts while the draft is one line; multiline drafts retain cursor navigation
- `/` or `Ctrl+P`: open a compact command palette; typing searches the full registry
- `/help`: open the deterministic capability reference without invoking a provider
- `/verify [goal]`: authorize and start an interactive isolated verified change
- `/changes`: inspect retained patch/check evidence and resolve Apply/Discard
- `/new` or `Ctrl+N`: start a clean Session
- `/resume`: pick and reopen a previous Session
- `/fork`: branch the current Session at its latest durable sequence
- `/rewind <sequence>`: branch the current Session at an earlier durable sequence
- `/tree` or `Ctrl+B`: navigate the durable SessionFork tree; `F` forks the selected node
- `/export`: write a deterministic Markdown Session export inside `.reycode/exports`
- `/advise [brief]`: run an explicit review through the configured Advisor Participant
- `/advise strategy [focus]`: review recent Workspace work for evidence-backed strategic alternatives
- `/hub`: inspect and control delegated child Invocations; press `M` on an `awaits merge` child to Apply or Discard its isolated patch
- `/runs` or `Ctrl+O`: inspect durable ToolRun ownership, arguments, authorization, output, and errors
- `/home`: return to the Session home
- `/agent`: create a Task Participant
- `/agents`: change a Participant's provider/model
- `/connect`: open provider configuration without model completion
- `/model`: switch the Assistant model in one step
- `/task`: delegate one task to one Task Participant
- `/answer`: open the waiting OperatorQuestion picker
- `/artifacts`: inspect and page retained large ToolRun outputs
- `/context`: inspect the latest provider-facing ContextSummary
- `/decisions`: browse or invalidate recorded implementation decisions and assumptions
- `/history` or `Ctrl+R`: search prior Operator prompts and restore one to the composer
- `/hotkeys`: show effective named action bindings and their configuration source
- `/plan`: inspect the newest Invocation WorkPlan
- `/steer <correction>`: queue a correction for the active Invocation's next provider-round boundary
- `/retry`: create a new Turn linked to the newest failed terminal Turn
- `/dequeue`: cancel the newest queued FollowUp and return its body to the composer
- `/cancel`: cancel the current Turn
- `/tools`: review a pending ToolRun approval
- `/workspace`: show the current Workspace path
- `/theme`: cycle the terminal theme
- `/quit`: exit ReyCode

│
- `!cmd`: run a shell command in the workspace; output lands in the transcript
- `@file` / `#file`: attach a file's content to the next message (workspace
  files only, 512 KB per file, 2 MB total). Typing `@` or `#` opens bounded
  recursive fuzzy file completion; paths containing spaces are quoted.
- `Tab`: cycle through the transcript, visible action controls, and prompt
- `Ctrl+A`: open the waiting OperatorQuestion picker
- `Ctrl+B`: open Session Tree
- `Ctrl+O`: open ToolRun Inspector
- `Ctrl+R`: search prompt history
- `Ctrl+G`: configure agent runtimes and models
- `Ctrl+T`: cycle the theme
- `j` / `k`: scroll the focused transcript
- Mouse wheel: scroll the transcript under the pointer without changing the draft
- `Ctrl+Q`: exit

If your terminal consumes Ctrl+Q for software flow control, use `/quit` or run
`stty -ixon` before launching ReyCode. This is a terminal setting, not a model
or Session problem.

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

### Cyberpunk terminal interface

ReyCode's default interface takes inspiration from
[CyberArch-Shell](https://github.com/ARCANGEL0/CyberArch-Shell) and Cyberpunk
2077's Blackwall: near-black panels, cut-corner input frames, and one rule for
color. Structural lines sit in dim crimson just above the background so the
transcript leads. Electric cyan marks focus and interaction only: the focused
composer frame, focused controls, and the palette scanner. Bright red is
reserved for state, such as errors, cancellation, and the breach sweep. Amber
means waiting or review, green marks success, and error labels stay explicit
alongside their red highlights. Conversation text stays cool white, inline
code is a pale sand tint, and metadata is warm gray.

Tall terminals reveal a large wordmark that resolves from scrambled glyphs in
700 ms. Typing immediately settles it without delaying or consuming input.
The home dashboard has traveling scan lines, a scanning geometric emblem,
and animated signal bars. These are decorative effects, not progress or
resource-usage measurements. The wordmark occasionally glitches while the
composer is empty.

At **120 columns × 28 rows** or larger, a side panel shows workspace context
on home and, during a Session, the newest tool runs: the verb, its file or
command, and elapsed time for active work. The header already carries state,
usage, and workspace, so the panel never repeats them. Smaller windows reclaim
the panel's space for the transcript. Menus share a dim header strip, and the command palette has
its own scanner.
Animations use lightweight renderer decorations without rebuilding the
conversation on every decorative frame. The existing `Ctrl+T` / `/theme`
controls still cycle palettes.

The Session header includes the wordmark and a boundary strip, the Assistant
runtime, Workspace, branch, and token context, followed by a persistent work
pulse derived from the Projection:

```text
⠹ · Reading · lib/foo.ex · 5s
```

The pulse shows the highest-priority truthful activity, including its bounded
file, command, approval, or delegated-work target when one exists. Thinking
omits the redundant Assistant name. Queued and waiting work remain truthfully
labelled (`… · Queued`, `Ⅱ · Paused · bash approval required`); terminal
completed/partial/reworked/failed/cancelled Outcomes use stable, distinct
glyphs.

Each Message forms a compact transcript labeled `You` or by the Assistant or
task participant's name. An Assistant Message places its execution ledger
before the final response: native reasoning and tool lifecycle events remain in
provider frame order, while a tool's start/update/completion lifecycle collapses
to one recognizable row. Rows are aligned columns, with the state glyph, the
verb, then the target in gray: `⠹ Reading    lib/foo.ex`,
`✓ Ran        mix test`, or `⠹ Delegating Luna`. Consecutive completed runs of
one verb fold into a single counted row such as `✓ Ran ×4` followed by their
targets until **Show details** expands them. Reasoning previews sit behind a
single `┆` rail as a quiet block; a fenced code block inside a preview collapses
to one `code omitted` row. The ledger keeps the eight newest reasoning previews
visible and reports older entries as `+k earlier thoughts`. Each preview wraps
to the available terminal width, including wide Unicode characters and long
unbroken tokens, rather than disappearing past the right edge.

Successful completed execution collapses to a tool-action count and a **Show
details** control. Clicking it, or pressing Enter/Space while it is focused,
reveals the execution ledger; active and failed work remains visible. Scrolling
away from the bottom suspends automatic following; End returns to the latest
output. Expansion is transient and clears when selecting another Session.
The composer grows with multiline drafts within a bounded height and labels
submission as Send or Queue according to ordinary Session scheduling. Its
state, such as `[ Ready ]`, sits bracketed at the right edge of the composer
header in the state color.

Expanded `edit` and `write` ToolRuns render bounded exact before/after
fragments directly below their activity row. The full ToolRun remains available
through `/runs`; presentation-only diff metadata is never sent back to the
provider. Mermaid `flowchart` and `sequenceDiagram` fences render as bounded
ASCII diagrams inside the final response. The active Invocation tier meter and
work pulse remain visible while the timeline preserves durable Invocation
order. A waiting-question indicator opens with `Ctrl+A`; the budget meter and
composer warn at 80 percent without stopping the Invocation.

The conversation screen uses a Blackwall-inspired theme: burgundy-black panels,
dim crimson boundaries, cyan focus and response accents, and yellow REYCODE
branding. Its motion language borrows from Cyberpunk 2077's netrunning.
Sending a message is a **breach**: for 600 ms the header boundary rolls Breach
Protocol hex bytes in red, then settles into an upload sweep that stays red
while the model works and turns cyan once response text streams in. Completion
plays a short closing sweep; a failed or cancelled turn leaves a broken rule
behind it. Every Session carries a **relic tag**, four hex digits derived from
its identity, shown after the wordmark and in the HUD; its digits roll during
a breach and resolve left to right as the work settles. Wide terminals show a
**Blackwall hex matrix** in the HUD: still bytes when idle, ICE cells flashing
through it during a breach, and a scan drifting across it while data streams.
The work pulse carries small signal bars while anything is active, and an empty
conversation resolves its wordmark from scrambled glyphs. Narrow terminals
retain the header strip and tag alone. Completion plays a short closing sweep before returning to idle. Errors,
cancellations, tool activity, and approvals keep their explicit status labels;
the effects are decorative, not connection telemetry. Transcript text, code,
selection, and the draft are never distorted. Opening an existing Session does
not replay its historical breach or completion effects.

Set `REYCODE_TUI_REDUCED_MOTION=true` before launching (or
`tui_reduced_motion: true` in application configuration) to use a static active
glyph and one-second elapsed-time refresh instead of frame animation. This
also disables every decorative animation, logo scramble, and glitch while
retaining the HUD layout and palette. Basic terminals use ASCII effect glyphs.

Streaming update bursts share a screen refresh, and unchanged Markdown formatting
is reused during menu navigation. While a question picker is showing options or
its review tab, Enter and Space belong to the picker even if a transcript control
still has keyboard focus. Multi-select questions use Space to select options and
Enter to advance.

Token usage in the header is cumulative provider-reported processing for the
Session; it is informational and is not current context occupancy. When exact
preflight is available, the header separately shows the latest encoded request's
estimated token occupancy or its tighter byte ceiling.

Before each provider request, ReyCode assesses the exact encoded body against the
resolved provider/model limits. At 80 percent it first records a bounded
extractive ContextSummary and durable ContextBoundary over eligible earlier
Messages, reducing toward 60 percent. Current inputs for active or queued Turns
remain verbatim. The timeline keeps the complete transcript and inserts a visible
compaction divider; `/context` shows the summary sent with later Messages.

Long-running provider/tool loops also maintain their active Invocation context.
Before a continuation is sent, providers with exact preflight support trigger a
durable summary at 80 percent of the request budget and reduce toward 60 percent.
Only complete older rounds are summarized; the newest round, full execution
ledger, ToolRuns, Events, and visible transcript remain intact.

Transient provider failures retry only when durable state proves that the failed
request produced no output and started no tool. ReyCode records the retry before
waiting 1 second and then 3 seconds, for at most three requests per ProviderRound.
Dispatched timeouts, partial output, and interrupted real-provider requests fail
closed instead of being replayed. A restart completes an already-recorded final
round or continues after terminal ToolRuns without repeating them.

The conversation view separates exchanges with whitespace and marks your
message text with a subtle `│` rail. On terminals at least 32 rows tall,
answers have an extra row below their header and each exchange opens with a
dim rule carrying the time after one blank row; shorter terminals drop the blank
row. Fenced code in an answer sits on the panel surface with one cell of
padding. A conversation with no messages yet shows the wordmark above `Ready`.
The session header reserves less empty space so more of the transcript stays
visible.

Completed replies use a compact checkmark. Thinking-only replies disclose
`Thinking · Show details`, tool activity shows an action count, and replies
without activity have no details control. Live work and failures remain
visible; expanding completed details preserves the existing keyboard and
mouse controls.

Use **Copy** on an answer header (click, or Tab then Enter) to copy the answer's
Markdown without thinking notes, status labels, or transcript borders. Clipboard
writes use `pbcopy` on macOS or `wl-copy` on Wayland, with explicit errors when
unavailable, unsuccessful, or over the 10 MB copy limit.

For selecting part of the visible text in **Ghostty**, hold **Shift while
dragging**, then press **Cmd+C** on macOS. If your Ghostty configuration lets
applications capture Shift-mouse events, set `mouse-shift-capture = never` in
Ghostty's configuration. This keeps ordinary mouse scrolling and buttons
working while reserving Shift-drag for terminal selection. See
[Ghostty's mouse selection settings](https://ghostty.org/docs/config/reference#mouse-shift-capture).

Answer and reasoning chunks are persisted as they arrive from the provider's
byte/latency buffer, including before stream completion. Characters split across
stream events wait for their remaining bytes before being recorded. Incomplete
characters at stream completion and malformed text in older transcripts display
as replacement characters rather than crashing the terminal. Answer text that
resumes after a tool round starts a new paragraph, so sentences from separate
rounds are never glued together. Active thinking stays
visible; after completion it collapses under **Thinking · Show details**.

## Challenge a claim against evidence

Use `/challenge` to choose a recent answer or a recorded decision/assumption,
then ask what supports it, what contradicts it, which assumptions are untested,
whether a simpler alternative exists, or what experiment could distinguish
the alternatives. You can also activate **Challenge** on a terminal answer's
header, or press `C` on an entry in `/decisions`.

Configure a task Participant named **Advisor** first (`/agent`, then `/agents`).
This picker operates in ordinary Sessions; verified-change Sessions retain
their separate `/changes` evidence and acceptance workflow.
The challenge uses the existing frozen strategic-review lifecycle with **zero
tools**: it cannot silently change files or run the proposed experiment.
Recorded actions and results are distinguished from model-authored explanations;
displayed thinking is not proof of why a model acted.

Reopen `/challenge` and select **Evidence / follow-up** on a review to inspect
packet-local citations such as `T1.I1.R1` or `M1`. The browser shows the captured
preview, durable source IDs, missing/clipped flags, and artifact-availability
limits. It does not claim to inspect current artifact or file contents.
Only citation-validated reports offer **Prepare follow-up** entries: these put
the proposed experiment and originating review ID into your composer, preserving
any existing draft. Review and send it as a separate task; preparation runs no tools.

Selection is bounded to the newest 100 message references in the current Session
and 100 workspace decisions/assumptions. An answer challenge captures its selected
Invocation and parent Turn, not a complete workspace audit; a decision challenge
captures that memory record only. Existing packet limits still apply (including
clipped previews and at most two retained terminal ToolRuns). Missing evidence
must remain an explicit limitation. Per-round prompt inspection and automatic
verification of free-text evidence claims are not provided by this view.

## Decisions and assumptions

ReyCode treats unstated assumptions and implementation choices as traceable
work. When materially different paths require your judgment, the assistant uses
`ask_operator`. Otherwise it records a typed `decision` or `assumption` in
ProjectMemory before proceeding, with rationale, alternatives, and concrete
file/ToolRun evidence. Memory updates execute directly by default, and the timeline
shows the recording ToolRun as `Recorded · <key>`.

Use `/decisions` to browse active and invalidated records for the current
Workspace; `Y` invalidates a stale record without deleting its append-only
history. Session Markdown/HTML exports include active decisions and assumptions
plus bounded ToolRun arguments. Decisions that must travel with the repository
belong in its `DECISIONS.md` through an approved edit; workspace-local rationale
stays in ProjectMemory across Session forks.

Successful ToolRun output larger than 16 KB is retained in the bounded artifact
spool instead of being copied wholesale into the transcript or provider
context. The result includes a preview and `artifact://` identifier. Use
`/artifacts` to inspect retained output; providers can request bounded byte
windows with `artifact_read`. Retention defaults to 128 artifacts and 2 MB per
artifact and is configurable with the `REYCODE_ARTIFACT_*` settings.

An OperatorQuestion may group one to four ordered questions, each with two to
five options, descriptions, and bounded previews. The compact picker replaces
the composer without hiding the transcript or changing its draft, and labels
the paused Invocation as waiting for the Operator's answer. Number keys,
arrow keys, and mouse clicks choose options; `Space` toggles multi-select
options; left/right or Tab changes question tabs; and the Other row accepts
bounded custom text. Review confirms all answers atomically. `[` and `]` switch
simultaneous requests from different agents. Escape leaves the custom editor or
durably rejects the whole request.

Submitting an ordinary message while the Session already has active or queued
work records a durable FollowUp Turn. `/dequeue` cancels only the newest queued
FollowUp and restores its body to the composer; it never cancels executing
work. `/steer <correction>` records bounded Steering on the one active
Invocation. The exact pending Steering IDs are included in the next provider
request and moved into that ProviderRound only when its response is durably
recorded; steering that arrives during a stream therefore forces another round
instead of being lost.

In the action palette (`/` or `Ctrl+P`), start with six goals: **New conversation**,
**Resume a conversation**, **Choose a model**, **Work with task agents…**,
**Review work…**, and **Settings…**. Review, task-agent, and settings groups open
smaller menus; `Esc` returns to the main menu, then restores your original draft.
Up to three relevant actions—such as a pending approval, a question, or stopping
active work—appear first. When setup is needed, connecting a provider replaces
the ordinary model choice.

Action names lead; slash spellings appear as secondary shortcuts. Search with
phrases such as `switch model`, `why`, or `check changes` after `/`. Existing
slash commands and their argument completion still work. The model summary on
the home and conversation screens also opens model/participant settings when
activated, so you can reach that flow without remembering a command.

Typing searches the full command registry. Arrow keys move the selection,
Tab accepts the highlighted completion without executing it, Shift+Tab moves
backward, Enter runs it, and Escape returns to the draft. Commands complete
current task Participants, provider/models, and Sessions. `@` and `#` mentions
fuzzy-search a bounded recursive Workspace file index. Dynamic arguments are
revalidated when submitted. `/cancel` stops the current task and `/tools`
reviews a pending tool approval.

Developer environment tools include structured Git status/diff/review/commit and
conflict-resolution operations, DAP debugger sessions, persistent Python and
JavaScript evaluation kernels, web search, rich URL/PDF/HTML/JSON reading,
project memory, and an opt-in Advisor review. Git commits, conflict resolution,
debugger execution, evaluation, and memory mutation follow configured tool permissions.
`/hub` opens the live delegated-child control surface. Wide terminals show a
roster and selected-Invocation inspector together; narrow terminals use `Tab`
to switch panels. `T` toggles flat/tree lineage, `M` reviews a pending patch,
and `C` cancels the selected child. `/advise` queues an explicit review through
the Task Participant named `Advisor` and never enables background review
implicitly.

### Strategic review

Create a Task Participant named `Advisor` with `/agent`, configure its model,
then run `/advise strategy` or `/advise strategy form handling`. The reserved
`strategy` subcommand reviews up to eight terminal task Turns across Sessions
in the current exact Workspace, ordered by task input sequence rather than
completion time. Failed and cancelled work can be evidence too. Ordinary
`/advise` and other custom briefs retain their existing behavior.

The review freezes task requests, selected Invocation reports and terminal
ToolRun previews, plus up to twenty project-memory entries. Its 64 KiB packet
discloses omitted and clipped content; external artifacts are not fetched.
Memory is captured separately from conversation history, not as an atomic
cross-store snapshot. Selection refuses stores exceeding 10,000 Turn records
rather than silently scanning an arbitrary subset. Prior strategic reviews
and identifiable verified report stages are excluded; historical unclassified
advisory text may still appear in ordinary task history.

Reports contain at most three findings with observations, causal hypotheses,
concrete implementation alternatives, tradeoffs, small experiments, uncertainty,
and packet-local citations. Recurrence requires evidence from two distinct
Turns. Citation checks establish provenance, not correctness; insufficient
evidence is a valid result.

This mode enforces zero tools, including delegation and memory writes. It does
not change files, launch experiments, or approve decisions. Successful reports
render in the transcript; invalid reports remain failed output. Retry reuses
the original packet, while a new command captures fresh evidence. Steering a
frozen review is rejected: cancel it and submit another review instead. Run
this command from an ordinary Session, not a verified-change Session.

On macOS, event data is stored transactionally in
`~/Library/Application Support/ReyCode/rey_code.sqlite3`. On first launch, a
legacy `~/.local/share/rey_code/events-v2.ndjson` log is imported and retained
with a `.pre-sqlite-backup` rollback copy.

The database may contain Sessions from many Workspaces. Interactive startup
matches Sessions by exact canonical Workspace path; trusted roots authorize
filesystem access but never choose the active Workspace.

## Architecture

```text

ReyCode.Application                     rest-for-one dependency supervision
|-- AgentRegistry (registered `Registry`)     unique process registry for Agent workers
|-- EventRegistry (registered `Registry`)     duplicate process registry for subscriptions
|-- ReyCode.EventStore                   transactional SQLite event store
|-- ProviderTaskSupervisor (registered `Task.Supervisor`)  bounded discovery task supervisor
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
authoritative. The gate is resolved through the headless squad runner's `a`/`r`/`b`
prompt — approve, return to integration, or abort — not a TUI command.

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

Run one live squad from the command line with a keyed model API profile
or a keyless local model server. Use `--workspace` to choose the
project directory; otherwise the current workspace is used. The `--release`
flag selects the release authority (`auto` for leader-authoritative, `wait`
for owner review):

```sh
mix rey_code.squad \
  --provider deepseek \
  --model deepseek-chat \
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
(for example, Luna on DeepSeek and Local on the keyless Ollama
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
Workspace roots and tool permissions are identical to ordinary runs. Tools
execute directly by default; an explicitly configured approval requirement
needs an interactive run.

## Model API setup

Press `Ctrl+G`, `/connect`, or `/agents` to select a model for the Primary
Assistant or a task agent. ReyCode connects directly to OpenAI-compatible chat
completion APIs. Each response returns normalized text, usage, and tool calls;
ReyCode executes approved tools and sends their results in the next model round.

Existing Sessions that used OMP or OpenCode retain their history and provider
attribution. Those providers are retired and cannot run new work. Reassign the
Session's participants through `/connect`; no credentials or model identities
are transferred automatically. The former CLI executable and process-limit
settings no longer apply. Configure request limits on model API profiles.

DeepSeek ships as a built-in keyed profile. Set its API key in your
environment and select a model in `Ctrl+G`:

```sh
export DEEPSEEK_API_KEY=sk-...
```

You can also enter keys directly in the wizard. In `Ctrl+G`, select a keyed
provider that shows `key required` and press Enter (or `K`): type or paste the
API key into the masked field and press Enter. ReyCode checks the connection
immediately — no restart — and advances to model selection when it succeeds.
With the `save` toggle on (default on macOS), the key is stored in the system
Keychain and survives restarts; toggle it off to keep the key for this run
only. `X` on a provider row removes its stored credential, and the step shows
which credential source is active. Keys never enter conversation history,
events, logs, diagnostics, or tool subprocesses. `Tab` toggles save; on
platforms without a system keychain, keys apply to the running process only.

Credential resolution order: a key entered this run wins over the environment,
and the environment wins over the system Keychain — so an export always
overrides a previously saved key after a restart.

More cloud providers ship as built-in keyed profiles. Export the matching key
and restart ReyCode; each row then lists its models in `Ctrl+G`:

| Provider | Key env | Base URL |
|---|---|---|
| Z.ai | `ZAI_API_KEY` | `https://api.z.ai/api/paas/v4` |
| Z.ai Coding | `ZAI_CODING_API_KEY` | `https://api.z.ai/api/coding/paas/v4` |
| OpenRouter | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` |
| Groq | `GROQ_API_KEY` | `https://api.groq.com/openai/v1` |
| xAI | `XAI_API_KEY` | `https://api.x.ai/v1` |
| Mistral | `MISTRAL_API_KEY` | `https://api.mistral.ai/v1` |
| Moonshot | `MOONSHOT_API_KEY` | `https://api.moonshot.ai/v1` |
| Together | `TOGETHER_API_KEY` | `https://api.together.xyz/v1` |
| Fireworks | `FIREWORKS_API_KEY` | `https://api.fireworks.ai/inference/v1` |

Ollama and LM Studio ship as built-in **keyless** profiles targeting
`http://localhost:11434/v1` and `http://localhost:1234/v1`. They need no
credential: requests through them never carry an `Authorization` header, not
even an empty bearer token. Start your local server and both appear in
`Ctrl+G`; discovery queries `/models` on the same schedule as every other
provider.

ReyCode reads keys from the environment at invocation time only. They are
never written to the event log, the catalog snapshot, or the diagnostics
report. On first use, the `/models` endpoint is queried once to populate the
model picker; discovery refreshes periodically and whenever you press `R`.

When a provider is unavailable in `Ctrl+G`, its row states the reason and the
fix — restart with a missing key, start an unreachable local server, or load a
model on an empty listing — and `D` shows a sanitized technical detail line
(failure category, HTTP status or connection cause) with no request bodies.


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

Profiles are the fallback request limits. Exact model IDs can override them
without guessing from model-name prefixes:

```elixir
config :rey_code,
  openai_compatible_model_budget_overrides: %{
    openai: %{
      "gpt-example" => %{
        max_prompt_bytes: 1_000_000,
        context_window_tokens: 128_000,
        output_reserve_tokens: 16_384,
        output_limit_parameter: :max_completion_tokens
      }
    }
  }
```

Resolution order is profile fallback, trusted exact-ID built-in, then configured
exact-ID override. `output_limit_parameter` is `:none`, `:max_tokens`, or
`:max_completion_tokens`. The built-in Z.ai and Z.ai Coding `glm-4.7` budget uses
a 200,000-token context, a 2,000,000-byte request ceiling, and sends the planned
output reserve through `max_tokens`.

Override any profile's base URL at runtime without changing config:

```sh
export REYCODE_ZAI_BASE_URL=https://api.z.ai/api/coding/paas/v4
```

Both Z.ai endpoints are also built-in profiles: **Z.ai** targets the standard
API and **Z.ai Coding** targets the Coding Plan endpoint. They are separate
profiles with separate key entries (`ZAI_API_KEY` vs `ZAI_CODING_API_KEY`), so
pick the one matching your subscription instead of overriding the base URL;
the export remains as an escape hatch. Usage and billing differ between the
two endpoints.

Provider reasoning (`reasoning_content` or `reasoning`, when supplied by the
model) appears live in the transcript as a growing thought block. It uses the
same byte- and latency-bounded batching as answer text, including during pauses
in the stream. The “Thinking” pulse remains a waiting indicator when the
provider has not supplied reasoning text.

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
rejects `stream_options`, the stricter shape is remembered and the durable
ProviderRound retry lifecycle makes the next bounded request without it. If the
server then still rejects the request while tools were offered, the invocation
fails non-retryably with `tool_calls_unsupported`, naming the flag to pin.
Dropping tools silently to degrade into chat-only mode never happens.

Fresh Sessions copy the current Assistant and task-agent runtime assignments.
Sending is blocked only when the addressed agent has no ready runtime. The
ReyCode-owned tool loop is the only execution path for model APIs and the
test simulator. Providers cannot execute tools on ReyCode's behalf.

### Tool security model

Providers can request workspace and developer-environment tools — `read`,
`write`, `edit`, `bash`, `grep`, `glob`, `list`, `lsp`, `process`, `git`, `debug`,
`eval`, `memory`, `web_search`, and `read_url`. ReyCode executes them inside
trusted Workspace roots where applicable. Read-only inspection runs after
containment checks. Supported tools run directly by default; configured rules
can require approval or deny execution. Unknown tools fail closed. See
[Tool approval](#tool-approval) for the approval surface.

The model receives explicit argument schemas for every advertised tool. Basic
filesystem tools require `path` (`.` means the workspace root); `glob` and
`grep` also require `pattern`, `bash` requires `command` with optional `cwd`,
and `write` requires `content` as well as `path`. `read` accepts optional
1-based `offset` and positive `limit` line counts.

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
and `restart` change process state; `list`, `logs`, and bounded readiness `wait`
only inspect Hub state. Processes retain only the newest configured output
bytes and are terminated when the supervised Hub stops.

`git` provides bounded status, diff, branch, conflict, review, staged-commit,
and conflict-resolution operations. `debug` drives a configured DAP adapter for
breakpoints, threads, stack frames, scopes, variables, evaluation, stepping,
and controlled execution. `eval` keeps one bounded Python or JavaScript
namespace alive between calls.

`web_search` uses an explicitly configured JSON search endpoint. `read_url`
normalizes bounded HTML, JSON, text, and PDF responses when `pdftotext` is
installed. `memory` stores append-only project facts and lessons in SQLite;
`recall` and `reflect` inspect them without mutation.

## Tool approval

Providers can only request workspace tools — `read`, `write`, `edit`, `bash`,
`grep`, `glob`, `list`, `lsp`, `process`, `git`, `debug`, `eval`, `memory`,
`web_search`, and `read_url`. Read-only inspection runs after containment
checks. Tools execute directly by default, including Bash, Write, and memory
updates. Unknown tools fail closed. Configure optional permissions in Elixir:

```elixir
config :rey_code, tool_permissions: %{
  default: :allow,
  rules: [
    %{tool: "bash", action: :ask},
    %{tool: "bash", pattern: "mix test*", action: :allow},
    %{tool: "bash", pattern: "git push*", action: :deny},
    %{tool: "write", pattern: "private/*", action: :deny}
  ]
}
```

Actions are `:allow`, `:ask`, and `:deny`. Rules are ordered: the last matching
rule wins. Tool `"*"` matches every executable tool. Optional patterns match
the supplied `command` for Bash and canonical `path` for file tools (`*` and `?`
wildcards). Relative path patterns use the canonical workspace-relative path;
absolute patterns use the canonical absolute path, including symlink resolution.
Patterns are supported for `bash`, `read`, `write`, `edit`, `glob`, `list`, and
`grep`; other tools accept tool-wide rules only. Missing or oversized pattern
inputs, unresolved paths, and exhausted matching budgets deny execution with
a diagnostic category rather than falling back to an allow rule.
Command patterns match the whole submitted string, not individual shell commands.
Rules are limited to 128 entries and patterns to 512 bytes; invalid config
fails at startup. Workspace containment, deadlines, output limits, and
verified-change acceptance still apply independently of tool permissions.

Configure the additional tools with these environment variables:

```sh
REYCODE_TOOL_DEBUGGER_COMMAND=/usr/bin/lldb-dap
REYCODE_TOOL_EVALUATION_PYTHON_COMMAND=python3
REYCODE_TOOL_EVALUATION_JAVASCRIPT_COMMAND=node
REYCODE_WEB_SEARCH_ENDPOINT=https://api.search.brave.com/res/v1/web/search
REYCODE_WEB_SEARCH_KEY_ENV=BRAVE_API_KEY
```

Git inspection is read-only; commits and conflict resolutions execute under
the same configured permissions as debugger, evaluation, and memory calls.
Web search requires an explicitly configured endpoint and key environment
variable; credentials are read at invocation time and never persisted.

A Workspace can auto-allow familiar Bash commands with
`.reycode/approval_rules.json`:

```json
{
  "version": 1,
  "allow": {
    "bash": ["git status", "mix test *"]
  }
}
```

Rules are per Workspace. Each entry is either an exact command or one trailing
` *` wildcard; the wildcard matches the base command and its arguments.
Commands containing shell control operators never match. Missing, malformed,
oversized, or symlinked rule files do not grant an exception. These legacy
allow rules apply only when configured permissions resolve to `:ask`; they
never override `:deny` or allow an unknown tool.

When a tool needs approval, ReyCode emits one terminal bell for the newly
pending durable request and a banner appears above the current transcript:

    tool approval required  /  write  /  /tools

Run `/tools` (or click the banner's command) to open the review modal. For
`bash` it shows the exact command, working directory, the names of every
environment variable that will be passed through, and a reminder that Bash is
explicit host execution rather than a sandbox. For `write` it shows the target
path, content size, and a bounded preview. For LSP `rename` it shows the action,
file, new name, and workspace-edit scope. Process mutations show the action,
name, argv, and supervised host scope. Nothing resolves until you choose:
`A` approves and `D` denies immediately, the arrow keys (or `j`/`k`) highlight
a choice that `Enter` confirms, and `Enter` with nothing highlighted leaves the
request pending.

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

Providers can pause only their own Invocation for one bounded grouped request:

    ask_operator  {"questions":[{"header":"Release","question":"Which release path?","options":[{"label":"Safe","description":"Run every gate"},{"label":"Fast","description":"Prefer speed"}],"recommended":0},{"header":"Region","question":"Where should it run?","options":[{"label":"Local"},{"label":"Cloud"}]}]}

The envelope, its one to four ordered questions, and each question's two to five
options are durable. The compact picker opens automatically, and `/answer`
reopens it when needed. Tabs collect partial answers locally; Review submits all
answers atomically in frozen order. Escape outside the custom editor durably
rejects the request. Confirmation or rejection completes the originating
ToolRun and re-arms the Invocation. This is not tool authorization and grants no
execution authority.

Providers maintain visible phased progress with `update_plan`. `init` accepts
ordered phases and unique item names; later actions are `start`, `done`,
`block`, `unblock`, and `drop`. At most one actionable item is in progress.
When none is running, the earliest pending item auto-promotes. `/plan` renders
the newest WorkPlan without changing it.

### Selecting and copying chat text

Left-click and drag across chat text to highlight it. Release the mouse to copy
the selection automatically—no Shift or copy shortcut is needed. Selection
works in either direction, across messages, and with code blocks and Unicode
text. Soft-wrapped lines copy without artificial newlines; code indentation and
logical line breaks are preserved. Chat labels and controls are excluded.

While dragging, the displayed messages stay stable even if the answer is still
streaming. Move to a transcript edge to scroll farther, or use the mouse wheel.
Escape cancels a selection; resizing or switching Sessions cancels it too.
Ordinary controls activate on click release, not when starting a drag. A failed
clipboard write shows an error rather than a success notice. Selection uses the
same platform clipboard support as the existing whole-answer **Copy** action.

Token usage is informational. The header shows provider-reported tokens summed
across the Session's recorded rounds, including repeated input sent on successive
requests. This is neither context-window occupancy nor your provider subscription
quota, and there is no cumulative per-task token cap. The budget-tier picker and
`/tier` command have been retired. Older tier, budget, and failure records remain
readable without limiting new execution. Provider-round counts are also
informational: there is no local round cap. Work continues until the provider
finishes, the Operator cancels, or a real provider/tool failure occurs. Context
bounds, per-request deadlines, and output limits still apply.

The header and the Agent Hub inspector also estimate spend in USD — what the
reported tokens would cost at per-model list prices. Z.ai and DeepSeek list
rates are built in, and a bounded `pricing.json` in the ReyCode data directory
(`~/Library/Application Support/ReyCode` on macOS) overrides or adds models by
id:

```json
{
  "glm-4.6": { "input_per_mtok": 0.6, "output_per_mtok": 2.2 }
}
```

Estimates assume no cache discount and never consult subscription plans. When a
model has no rate, or a usage record lacks an input/output token split, the
spend shows as unavailable instead of a guess. Costs are computed at display
time from current rates and are not stored in history, so editing
`pricing.json` reprices past Sessions.

## Diagnostics

Inspect production readiness with the doctor task:

```sh
mix rey_code.doctor
mix rey_code.doctor --json
```

The report includes runtime and operating system versions, the resolved data and
database paths with permissions and available space when the platform exposes it,
model API readiness and sanitized endpoint origins, and configured
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
failing if total coverage drops below the 85% floor (`coveralls.json`). On pull
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
