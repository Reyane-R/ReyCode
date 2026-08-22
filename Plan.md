# Plan: Durable, Provider-Independent Tool Execution Layer

## Goal

Build an OMP-quality, provider-independent agent loop while retaining ReyCode's
durable orchestration:

```text
provider round
→ persist normalized assistant response
→ persist ToolRuns
→ authorize
→ pause or execute
→ persist results
→ rebuild conversation
→ next provider round
```

No provider may execute ReyCode-owned tools or recursively drive follow-up
rounds.

## Decisions

- `ToolRun` is a durable entity belonging to an invocation.
- Providers perform exactly one model round per call.
- Tool calls execute sequentially in v1.
- At most one owner approval is active per invocation.
- Waiting approval consumes no Agent process or admission slot.
- Approval resumes through a newly scheduled Agent using durable state.
- Owner denial fails the invocation, matching the existing plan.
- Policy denial becomes a tool error the model can correct.
- A crash after `tool_run_started` is indeterminate and fails closed; side
  effects are never automatically replayed.
- Bash is explicit host execution, not a filesystem sandbox. It always shows
  the exact command for approval and documents host access.
- OpenCode stdio remains an explicit legacy provider-managed-tools capability.

## Domain Terms

- `ToolCall`: normalized request returned by a provider.
- `ToolRun`: durable authorization and execution lifecycle for one ToolCall.
- `ProviderRound`: one assistant response, containing text and zero or more
  ToolCalls.
- `ToolResult`: durable JSON-safe result supplied to the next ProviderRound.

## Implementation Plan

1. **Lock the behavioral contract with failing tests.**
   Add end-to-end tests proving safe tools loop correctly, asks genuinely
   pause, approval executes once, denial finalizes, restart resumes, frames
   cannot overwrite waiting state, and multiple rounds preserve history. Start
   with the simulator and a fake executor.

2. **Introduce normalized provider conversation types.**
   Add `Provider.Message`, `Provider.ToolCall`, and `Provider.Response`.
   Extend messages to represent assistant tool-call batches and tool results
   keyed by call ID. Change `Provider.stream/3` to perform one round and
   return a normalized response. Remove tool execution from
   `Provider.Controller`; preferably collapse it back to a frame-emitter
   function.

3. **Add durable ProviderRound and ToolRun events.**
   Add `provider_round_recorded`, `tool_run_requested`,
   `tool_run_approval_resolved`, `tool_run_started`, `tool_run_completed`,
   `tool_run_failed`, and `tool_run_interrupted`. Project ordered rounds and
   ToolRuns under each invocation. Derive pending review from ToolRun state
   rather than storing an independent `pending_tool_review`.

4. **Build a deep `ReyCode.AgentLoop` module.**
   Keep `ReyCode.Agent` responsible for supervision, buffering, and lifecycle.
   `AgentLoop` should reconstruct durable context, process ready ToolRuns,
   call one provider round, persist returned calls, execute sequentially, stop
   on approval, and complete only when a provider returns no calls.

5. **Move continuation reconstruction into `InvocationRequest`.**
   Build provider messages from the original room context plus durable
   ProviderRounds and terminal ToolResults. Never depend on provider-local
   `tool_calls` or `tool_results` state. This enables approval and
   Engine-restart resumption.

6. **Repair Engine scheduling and finalization.**
   Approval by ToolRun ID should append the resolution and enqueue the
   invocation. Denial should use normal `finalize_invocation/3`, updating the
   message, turn, workflow, and admission state. Waiting workers should exit
   normally and release capacity. Recovery should leave awaiting runs dormant,
   enqueue approved runs, reuse completed results, and fail running runs as
   indeterminate.

7. **Adapt the simulator first.**
   The simulator should return deterministic ToolCalls in one round and return
   its final response only after matching ToolResults appear in the next
   request. This becomes the provider contract test and proves restart-safe
   continuation before touching live APIs.

8. **Adapt OpenAI-compatible providers.**
   Remove `continue_after_stream/2`, `apply_tool_completion/4`, and
   provider-local recursive state. SSE should assemble normalized ToolCalls
   and return them. Add tests using the real provider interface, including
   multiple rounds, malformed arguments, parallel call batches processed
   sequentially, and an explicit round-limit failure.

9. **Make OpenCode capability differences explicit.**
   Add provider capabilities such as `:reycode_tools` and
   `:provider_managed_tools`. Keep OpenCode stdio observational and document
   that it does not satisfy D22 until a serve/permission adapter exists.

10. **Deepen the tool registry.**
    Replace heterogeneous `term()` results with typed authorization and
    execution results. Publish real JSON schemas with descriptions and
    required fields. Validate and normalize arguments before approval, then
    revalidate immediately before execution. Confine path tools to the
    validated room workspace, while global roots only determine which room
    workspaces are permitted.

11. **Finish issue #30 tool semantics.**
    Add bounded line-oriented reads, unique edit matching, write/edit caps,
    binary-safe grep, symlink-safe traversal, glob containment, JSON-safe
    result metadata, and truncation flags. Bash must kill timed-out process
    trees, capture stderr, cap output, and report exit code, timeout,
    truncation, and wall time.

12. **Repair the approval UI.**
    Resolve by ToolRun ID. Show exact Bash command, cwd, environment names,
    write path, content size, and a bounded content preview. Add a visible
    pending-approval banner, document `/tools`, and handle stale decisions
    cleanly.

13. **Handle existing event data safely.**
    Stop emitting `tool_ask_*`, but retain replay support. Normalize old
    snapshots with empty rounds/ToolRuns. A legacy pending approval without
    resumable conversation state should fail as
    `legacy_tool_approval_unresumable`, never silently replay.

14. **Update architectural decisions.**
    Amend D22/D23 to distinguish ReyCode-managed and provider-managed tools.
    Document Bash as approved host execution rather than workspace-sandboxed
    execution. Keep the stronger default approval policy.

## Acceptance Matrix

- Allow-listed tool executes once and its real result reaches the next
  provider round.
- Ask tool produces no result or provider follow-up before approval.
- Approval after a complete Engine restart executes the exact persisted
  request.
- Denial performs no side effect and cleanly finishes the turn as failed.
- Waiting approvals consume no concurrency slot.
- Completed ToolRuns are reused and never replayed.
- Indeterminate running ToolRuns fail closed.
- Two or more tool rounds retain the complete conversation.
- Provider frames never mutate invocation lifecycle status.
- Out-of-workspace path tools fail before approval or execution.
- Bash timeout kills descendants and bounded output remains recoverable.
- OpenCode's legacy capability is visible and cannot be mistaken for
  ReyCode-owned execution.
- `mix check` and coverage remain green.

## Delivery Order

1. Simulator plus durable safe-tool loop. *(complete: normalized Provider
   Message/ToolCall/Response contract, durable provider-round and tool-run
   events with projection, `ReyCode.AgentLoop` owning the loop, engine
   round/run boundary, waiting-approval dormancy and restart recovery,
   simulator/OpenAI/OpenCode adapted; locked by
   `test/agent_loop_lifecycle_test.exs`)*
2. Durable approval, denial, recovery, and admission. *(complete: approval
   executes the persisted request exactly once, denial finalizes without side
   effects, waiting approvals survive restart and release capacity, turn
   cancellation clears reviews, legacy snapshots normalize safely, tool
   failures return durably to the provider, and concurrent writers no longer
   surface stale canonical-path misses; locked by
   `test/agent_loop_approval_test.exs`,
   `test/agent_loop_lifecycle_test.exs`, and
   `test/orchestration_projector_snapshot_test.exs`)*
3. OpenAI-compatible adapter hardening. *(one-round contract done; multi-round
   and malformed-argument integration tests pending)*
4. Tool security and issue #30 semantics. *(relative paths now resolve
   against the invocation workspace; caps, unique edits, symlink-safe grep,
   glob containment, bash process-tree kill remain)*
5. TUI, migration, diagnostics, and documentation.
6. OpenCode serve/permission bridge as a separate project.

## Non-Goals

- Parallel tool execution.
- Automatic replay of uncertain side effects.
- Filesystem sandboxing for Bash.
- OMP's 31-tool scope, LSP, browser, debugger, or native shell.
- OpenCode serve integration in this implementation.
