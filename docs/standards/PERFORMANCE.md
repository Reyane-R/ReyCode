# ReyCode Performance Envelopes

These are design envelopes, not benchmarks. Changes to a data-plane path update assumptions and verify the relevant bound.

## Provider streaming

| Dimension | Envelope |
|---|---|
| Request duration | 600,000 ms default provider deadline |
| OpenAI-compatible retained output | Profile maximum, 10,000,000 bytes default |
| Frame persistence | Each provider-batched frame is recorded before acknowledgement; no second count-only buffer |
| Text chunk target | 8,192 bytes |
| Text flush latency | 50 ms |
| Provider rounds | 16 per Invocation |

Design intent: network latency dominates. Buffer short text to reduce event transactions while flushing within interactive latency. Output caps bound binary retention and parsing.

Reasoning deltas share the text chunk byte and latency limits. Pending reasoning
flushes even during transport silence; batches carry their segment's first frame
sequence so the transcript joins them without repeating the growing prefix in
each durable event. The existing provider activity retention bound still applies.

Historical provider activity remains readable, bounded to the newest 256 events
per Invocation. New model API calls return text and ToolCalls; tool activity is
recorded through ReyCode's durable ToolRun lifecycle.

## Event storage and replay

| Dimension | Envelope |
|---|---|
| SQLite writer concurrency | One EventStore process |
| Append consistency | One transaction with expected projection sequence |
| Checkpoint interval | 500 projected events |
| Replay tail | 2,000 events |
| Checkpoint payload | 67,108,864 bytes |
| Retained checkpoints | 3 |

Design intent: append latency is serialized for correctness. Checkpoints bound startup replay work. Total event/database retention is not yet bounded and requires an explicit retention decision before sustained multi-user deployment.

## Engine admission

| Dimension | Schema default | Production runtime default |
|---|---:|---:|
| Global active Invocations | 2 | 2 |
| Workspace active Invocations | 1 | 1 |
| Global waiting work | 100 | 100 |
| Workspace waiting work | 20 | 20 |

Design intent: all shipped defaults are finite. Tests MAY inject `:infinity` explicitly when exercising policy semantics.

## Tool execution

| Tool/resource | Envelope |
|---|---:|
| Bash duration | 30,000 ms |
| Bash stdout | 256,000 bytes |
| Bash stderr | 64,000 bytes |
| Bash CPU | 120 seconds |
| Bash open files | 1,024 |
| Read bytes | 512,000 |
| Read lines | 2,000 |
| Edit bytes | 512,000 combined old/new input |
| Write bytes | 512,000 |
| Glob results | 10,000 |
| List entries | 2,000 |
| List duration | 10,000 ms |
| Grep matches | 1,000 |
| Grep file bytes | 512,000 |
| Grep files | 10,000 |
| Grep duration | 10,000 ms |

Design intent: tool work is host execution and always bounded by resource and workspace policy. Truncation is observable.

## Squad workflow

| Dimension | Envelope |
|---|---:|
| Provider attempts per work item | 2 |
| Rework cycles | 3 default |
| Concurrent phase work | Number of Roles assigned to the Phase, bounded by Engine admission |

Design intent: every cycle either advances, consumes rework budget, or terminates.

## Projection and TUI

| Dimension | Current behavior |
|---|---|
| Session/Message/Turn retention | Entire durable history retained in Projection |
| TUI render input | Current full Projection, presentation windows selected during rendering |
| Agent-note trail | Newest 100 notes per Invocation (`@max_invocation_notes` in Projector) |
| Provider activity trail | Newest 256 native note/tool events per Invocation (`@max_provider_activity_events_count` in Projector) |
| TUI reasoning lines visible | 8 per message behind a `+k earlier thoughts` collapse |
| Terminal dimensions | Runtime terminal size; tests include 50x20 through 160x32 |

The total Projection has no retention bound. Before long-lived multi-user operation, choose one of archival, pagination/windowed projection, or explicit memory/database capacity limits.

## Interactive verification

| Resource | Envelope |
|---|---:|
| Interactive coordinators | 2 global, 2 per source Workspace, 1 per initiating Session |
| Registered source-operation leases | 64 |
| Concurrent patch resolutions | 4, also constrained by the source barrier |
| Concurrent owner commands | 32 |
| Check capture | 1 MiB per stdout/stderr stream |
| Durable check preview | 16 KiB per check, 8 checks per baseline/final batch |
| Retained binary patch | 2 MiB |
| Source snapshot | 10,000 files / 128 MiB file bytes |
| Resolution operation | 60 seconds, individual Git commands at most 10 seconds |
| Expanded completed ledgers | 128 transient message IDs, reset on Session selection |
| Patch inspector visible rows | At most 24, reduced for terminal height |

Design sketch: provider networking is unchanged; local inspection adds no network
requests. Each journal update is one bounded SQLite event transaction; retained
patch evidence can add up to 2 MiB per update, so repeated verification is bounded
by eight checks and three repairs, not a constant-size log. CPU and temporary
Git object work scale with at most 128 MiB of candidate input per snapshot.
Inspector wrapping scans at most the 2 MiB patch per render/navigation; visible
rows are bounded separately. These are bounds, not measured latency claims.
Terminal tests cover streaming scroll preservation and 60x20 control visibility;
real PTY smoke exercises setup, approval, review, application, and resize.

## Strategic review envelope

An explicit review examines at most 10,000 projected Turns and 100 supplied
memory records; larger selection inputs return a tagged error. It retains up
to eight Turns, two Invocations per Turn, two terminal ToolRuns per Invocation
(at most 32 tool references examined per Invocation), and twenty memories.
The encoded packet is at most 65,536 bytes. Excerpts start at 1,024 bytes
(512 for tool previews); deterministic budget reduction discloses clipping and
omissions. Reports are at most 32,768 bytes with three findings.

Networking adds one ordinary bounded provider Invocation, with existing round,
token, and timeout limits. No source/artifact filesystem reads or extra model
calls collect evidence. Storage adds a bounded packet to the queued Turn and
existing Invocation prompt events; repeated reviews still accumulate durable
history under the store's existing retention policy. Memory and CPU for capture
scale with the explicit scan ceiling, selected previews, and bounded encoding
passes, not tool output or artifact file size. These are envelopes, not latency
measurements. Tests exercise clipping, encoded size, rejection at scan bounds,
frozen retries, and real Breeze report rendering at 40 and 120 columns.

## Performance sketch template

For a data-plane change record:

```text
Path:
Expected operations/second:
Peak operations/second:
Network bytes and latency:
Storage bytes and latency:
Retained memory:
CPU work per item:
Batch size:
Maximum duration:
Failure at each bound:
Measurement plan:
```

A sketch is complete when all four resources—network, storage, memory, compute—are addressed or explicitly not applicable.
