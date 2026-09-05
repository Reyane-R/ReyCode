# Operator Experience Pass — Implementation Plan

Working plan for the six-feature UX pass. Read this before reviewing the
implementation; it records every design decision and the reason behind it.
This file is working material — remove it once all phases ship.

Status: **planned, not started**. Phases ship in order; each ends with
`mix check`, `mix coverage`, README updates, and green CI before the next
begins.

| # | Feature | Phase | Est. | New events | New module(s) |
|---|---------|-------|------|------------|---------------|
| 1 | `-c/--continue` on `reycode run` | 1 | 0.5 d | none | — |
| 2 | `/init` | 1 | 0.5 d | none (reuses message flow) | — |
| 3 | "Always allow" (`L`) on the approval modal | 2 | 1 d | none | `ApprovalRules.add_pattern/3` |
| 4 | Completion notifications | 4 | 0.5 d | none | extends `Attention` |
| 5 | `/search` transcript search | 4 | 1 d | none | `TranscriptSearch` |
| 6 | Workspace checkpoints + `/undo` | 3 | 2–3 d | `turn_checkpoint_recorded`, `turn_checkpoint_consumed` | `Security.Checkpoint` |

Execution order is **1 → 2 → 4 → 5 → 3**: the trivial wins land first;
checkpoints ship last because it is the only feature with new durable events
and filesystem side effects.

---

## Phase 1 — `-c/--continue` and `/init`

### 1a. `-c/--continue` on `reycode run`

**User story.** A script runs `reycode run -p "…" --json` repeatedly and wants
each invocation to continue the previous conversation instead of starting a
new one.

**Behavior.**

- `reycode run -c -p "follow-up"` posts to the most recent durable session
  (last entry of the engine projection's `session_order`).
- `--workspace` is ignored under `-c`: the session carries its own workspace.
  Documented in usage text. Rationale: the user's mental model for "continue"
  is "the last conversation", not "the last conversation in this directory",
  and silently forking to a different workspace would split the thread.
- No durable session exists → fall back to the fresh-session path silently.
  The JSON report already contains `session_id`, so callers can detect which
  path ran. Non-JSON output stays exactly the response text (stdout remains
  parseable-by-eye).
- `-c` composes with `-p`, positional args, piped stdin, `--json`, and
  `--timeout-ms` unchanged.

**Changes.**

- `lib/rey_code/cli/run.ex`: parse `--continue` (`-c` alias); pass through.
- `lib/rey_code/one_shot.ex`: `options` map gains `continue?`; `run/2` skips
  `open_session/4` and posts directly to `latest_session/1`'s id. The
  `latest_session/1` helper already exists.
- README one-shot section: document the flag and the workspace rule.

**Tests.** Store with an existing session: `-c` grows that session's turn
count and reuses its `session_id`; empty store: `-c` behaves like a fresh run;
two consecutive `-c --json` runs report the same `session_id`; `-c` never
creates a second session.

### 1b. `/init`

**User story.** In a repo without `AGENTS.md`, one command makes the Primary
Assistant analyze the workspace and write one.

**Behavior.**

- Command registered in `Capabilities.commands()` — the palette, palette
  completion, and `/help` all derive from that single registry, so no other
  registration point is touched.
- Submitting `/init` checks the selected session's workspace for `AGENTS.md`.
  - Exists → palette-style notice: "AGENTS.md already exists"; no message is
    posted. (No overwrite flag in v1 — the file is the operator's to edit.)
  - Missing → posts a normal durable operator message whose body is a frozen
    instruction (module attribute, ~600 bytes): analyze the workspace using
    the bounded `read`/`list` tools, then write `AGENTS.md` via an `edit`
    covering purpose, layout, build/test commands, and conventions.
- The generated turn is an ordinary Primary turn: it appears in the
  transcript, is durable, and — because writing goes through the `edit`
  tool — the owner approves the actual file content. `/init` grants no new
  authority.
- Unconfigured Primary runtime → the existing send-blocking flow reports it;
  no special handling.

**Changes.** `lib/rey_code/capabilities.ex` (command entry),
one handler alongside the existing slash-command dispatch, README command
list.

**Tests.** Palette lists `/init`; submitting posts a message containing the
frozen instruction text; existing `AGENTS.md` produces the notice and no
message.

---

## Phase 2 — "Always allow" (`L`) on the approval modal

**User story.** The third time the assistant asks to run `mix test`, the
owner presses `L` instead of `A` and never sees that prompt again.

**Behavior and decisions.**

- New key on the `ToolReview` modal: `l`/`L` = add the run's exact command as
  an allow rule, alongside `A` approve / `D` deny.
- **Bash runs only.** D36 rules have no representation for `write`, `lsp`,
  `process`, `git`, `debug`, `eval`, or memory mutations. Other tool kinds
  render no `L` hint (the modal must not advertise an action that does
  nothing).
- **Rule shape: exact trimmed command.** No wildcard is ever synthesized; an
  owner who wants `mix test *` widens it by hand. Conservative default keeps
  the blast radius of a single keypress obvious.
- **Owner-side write, no approval gate.** Precedent: `OwnerCommand` — the
  Operator *is* the approver, and the modal is the Operator acting.
- **Merge, never clobber.** `ApprovalRules.add_pattern/3` loads the current
  file through the existing fail-closed loader; on any load failure (missing
  is fine, malformed is not) it refuses with the reason — a malformed rules
  file is never overwritten, the owner fixes it first. Valid merge: dedupe,
  reject patterns > 256 bytes, refuse when the 32-rule cap is reached
  (refuse, not evict — silent rule loss is worse than a visible limit).
  Re-encode canonically as `{"version": 1, "allow": {"bash": […]}}`.
  Hand-written formatting is not preserved; documented.
- **Effect is immediate.** `ApprovalRules.load/1` runs on every tool-run
  claim, so the *next* identical run auto-allows. The current run still needs
  `A` once; the modal notice says exactly that: "Rule added — identical
  commands are now auto-allowed; approve this run with A."
- **Escalation guard (new invariant).** The rules file lives in the
  workspace, so an assistant could ask to *write* it, get one approval, and
  thereafter self-authorize. `Write`/`Edit` deny provider-originated runs
  targeting `.reycode/approval_rules.json` with
  `{:error, :protected_path}`. Owner-modal writes go through
  `ApprovalRules` directly and are unaffected.
- Modal state after `L`: stays open (the run is still pending), notice set,
  hint shows "rule added". `A`/`D` still work.

**Changes.**
`lib/rey_code/security/approval_rules.ex` (`add_pattern/3`, pure merge
returned as `{:ok, document} | {:error, reason}` — no I/O in the merge),
`lib/rey_code/tui/tool_review.ex` (key clause, hint, notices),
`lib/rey_code/tool/write.ex` + `lib/rey_code/tool/edit.ex`
(`.reycode/approval_rules.json` → `:protected_path`), README tool-approval
section, **D36 amendment**: operator-initiated rule writes are owner actions
outside the approval gate; provider-originated writes to the rules file are
denied.

**Tests.** `add_pattern/3`: merge into valid file, dedupe, 256-byte cap,
32-rule refusal, malformed-file refusal, wildcard-shaped input refused.
ToolReview: `L` on a bash review writes the file and sets the notice; no `L`
hint for `write` runs; `L` with malformed rules file → fix-it notice, file
untouched. Tool layer: provider `write`/`edit` to the rules file →
`:protected_path`; owner-path write unaffected.

---

## Phase 3 — Workspace checkpoints + `/undo` (design: D37)

**User story.** The owner approves a mutation, the result is wrong, and
`/undo` puts the workspace back the way it was before the turn touched it —
including files the turn created.

**Architecture: shadow Git object store (OpenCode-verified design).**

- One shadow Git repository per workspace, stored under ReyCode's data dir:
  `<data_dir>/checkpoints/<sha256(workspace-path)[0..15]>/.git`. Every Git
  invocation runs with `GIT_DIR=<shadow>/.git` and
  `GIT_WORK_TREE=<workspace>`.
- **Zero footprint in the user's repo** — no commits, no refs, no index
  changes, no hooks, no `stash` entries. This is the property that makes the
  feature forgettable-until-needed, and it is the reason OpenCode chose the
  same shape (verified against their snapshots docs).
- **Capture scope** comes from the workspace's own `.gitignore` (the shadow
  index resolves ignore files against the worktree), which keeps
  `node_modules`, `_build`, and secrets-pattern files out for free. The
  shadow store force-excludes the workspace's `.git/` via its
  `info/exclude`. `.reycode/` **is** captured — reverting a bad rules edit
  via `/undo` is a feature.
- **Per-checkpoint operation** (worker-side, synchronous, before the first
  mutating run of a turn):
  1. `git ls-files -o --exclude-standard` — untracked file list (bounded:
     first 100,000 entries).
  2. Untracked files > 2 MiB are excluded via negative pathspec on the add
     (matches OpenCode's per-file cap; big artifacts are not undo targets).
  3. `git add -A` with those exclusions → `git write-tree` → tree SHA.
  4. `git update-ref refs/reycode/undo/<turn_id> <tree_sha>`.
  5. Durable event `turn_checkpoint_recorded` (turn id, ref name) — the ref
     is workspace-adjacent state, the event is the durable pointer the
     projector records on the turn.
- **Budgets** (bounded everything):
  - 2 MiB per untracked file (excluded, listed in the checkpoint event).
  - Retention: newest 20 `refs/reycode/undo/*` per workspace; older refs
    deleted and shadow `git prune --expire=now` run after each checkpoint.
  - Shadow store cap 512 MiB: on exceed, evict oldest checkpoints until under
    budget before writing the new one.
- **Restore (`/undo`)**, for the selected session's most recent
  checkpoint-bearing turn:
  1. Confirm modal: turn title, checkpoint age, and a bounded (100-row)
     name-status diff between the checkpoint tree and the worktree
     (`git diff --name-status <tree>` run in the shadow).
  2. Restore: `git read-tree <tree>` then `git checkout-index -a -f` —
     every captured file returns to its checkpoint content.
  3. **Created files are deleted**: paths present in the worktree but absent
     from the checkpoint tree (`ls-tree -r` vs worktree listing, bounded
     list) are removed, and every restored/deleted path is printed. Deleting
     is the point — "everything back the way it was" — and capture
     completeness is what makes it precise. Documented caveat, same as
     OpenCode's: manual edits made *during* the turn can be overwritten;
     review the printed summary.
  4. `git update-ref -d` + durable event `turn_checkpoint_consumed`. A second
     `/undo` reports "nothing to undo". `/undo` never touches conversation
     state — that is `/rewind`'s job; the two commands are orthogonal.
- **Failure policy: fail-closed for every mutating run.** If the checkpoint
  cannot be taken (no git root, git error, budget refusal, timeout), the run
  fails with `checkpoint_unavailable` *before any side effect*, approval
  path or not. One rule, no two-tier nuance. Escape hatch:
  `REYCODE_CHECKPOINTS=off` skips checkpoints silently (runs proceed
  unaudited-by-snapshot; the choice is visible in `/help`-adjacent docs).
- **Restart safety**: refs live in the shadow repo under the data dir, so
  `/undo` works after an engine restart. The projector rebuilds "checkpoint
  exists" from events; existence is still validated against the ref at undo
  time (the owner may have deleted the data dir).
- **Documented non-goals** (D37): bash side effects (databases, installs,
  network, processes) are not undoable; nested git repositories are captured
  as opaque directories; interrupted turns checkpoint only if the first
  mutation already ran.

**Changes.** New `lib/rey_code/security/checkpoint.ex` (pure: shadow paths,
argv builders, tree/worktree diff planner — fully unit-testable with no I/O),
worker integration at tool-run claim, `event.ex` /
`event_entries.ex` / `projector.ex` (two events), `/undo` command (confirm
modal in the `ToolReview` shape), runtime config `checkpoints` flag +
`REYCODE_CHECKPOINTS` env, README section, **D37**.

**Tests.** Planner argv/path purity. Lifecycle: approved `write` → ref
exists → `/undo` restores content and deletes the created file (paths
printed) → second `/undo` refused. Rules-allowed `bash` also checkpoints.
Non-git workspace → run fails `checkpoint_unavailable`. Env off → proceeds,
no events. Restart → undo still works. 2 MiB untracked file → excluded,
survives undo, listed. 21st checkpoint evicts the oldest. Provider
`write`/`edit` cannot touch the shadow store (outside the workspace roots —
existing containment covers it; one test pins it).

---

## Phase 4 — Completion notifications and `/search`

### 4a. Completion notifications

**Behavior.**

- `Attention` grows terminal-turn transitions: when a turn reaches
  `:terminal` and its id has not been seen, emit a signal. Seen ids live in
  an assigns `MapSet` (transient; mount-initialized) — a restart re-notifies
  once for in-flight turns, which is correct (the operator needs to know).
- **Noise rule**: signal only for turns that are *not* the selected session's
  visible activity — i.e., other sessions' turns and `detach: true`
  background turns. The focused session's completion is on screen; a bell for
  it is noise.
- Signal = terminal bell + OSC 9 (`ESC ] 9 ; ReyCode · <title> · <outcome>
  BEL`) for desktop notifications where the terminal supports it. Gated by
  the existing terminal-attached predicate and a new `tui_notifications`
  bootstrap config (`REYCODE_TUI_NOTIFICATIONS`, default on) — same pattern
  as `tui_update_check`.

**Changes.** `lib/rey_code/tui/attention.ex`, `lib/rey_code/tui/state.ex`
(seen-set + hook), `runtime_config` schema + policies, README.

**Tests.** One signal per turn; other-session and detached fire; focused
silent; config off silent; non-terminal transitions never fire.

### 4b. `/search`

**Behavior.**

- Modal cloned from `PromptHistory` (query input, ArrowUp/Down/Enter, Escape;
  256-byte query cap). Scans the **selected session's** durable messages in
  `message_order`: operator and assistant bodies, case-insensitive. Matches
  render as `author · time · excerpt` (160 bytes around the first hit),
  capped at 32. Enter opens the full message body read-only in the modal;
  Escape steps back / closes. ToolRun hits are v2 (the modal shape leaves
  room).
- Bound by construction: scan is projection-local (no EventStore queries), so
  cost scales with the session's visible messages, not store size.

**Changes.** New `lib/rey_code/tui/transcript_search.ex` (pure `search/2`),
command registry entry, `state.ex` assigns + dispatch, default keybinding
`Ctrl+F` in `keybindings.json` defaults (plus `/search`), modal render
component, README keybinding table.

**Tests.** `search/2`: case-insensitivity, excerpt window at hit, 32-match
cap, session scoping, empty-needle. TUI: open, type, match listed, Enter
opens detail, Escape closes, zero-match notice.

---

## Verification and docs strategy

- Every phase: `mix check`, `mix coverage` (pure modules carry the
  changed-line gate — all six features are built around pure cores:
  `add_pattern/3`, checkpoint planner, `search/2`), targeted TUI tests for
  every modal/keybinding, README updated (user-facing behavior is docs),
  CI green before the next phase starts.
- Decision-log entries: **D36 amendment** (operator-initiated rule writes;
  provider writes to the rules file denied) and **D37** (shadow-store
  checkpoints: capture scope, delete-created-files semantics, fail-closed,
  budgets, escape hatch, non-goals).
- `docs/plans/operator-experience-pass.md` (this file) is deleted when the
  last phase ships.

## Risks

| Risk | Mitigation |
|------|------------|
| Rules-file escalation (assistant self-authorizes) | `:protected_path` deny in Write/Edit; tested |
| Checkpoint pauses mutating runs on slow disks | Synchronous but bounded (git ops on ignored-scoped trees are small); budget refusals fail closed and are visible |
| Shadow store growth | Retention 20, 512 MiB cap, prune after each checkpoint |
| Notification noise | Other-session/background-only rule; config off-switch |
| `/undo` deleting wanted files | Printed restored/deleted lists; confirm modal shows the name-status diff before Enter |
| Changed-line gate platform drift | Pure cores + deterministic fixtures; render fixtures avoid `File.cwd!` and home-relative paths (lesson from PR #92) |
