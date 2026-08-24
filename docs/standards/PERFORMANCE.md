# ReyCode Performance Envelopes

These are design envelopes, not benchmarks. Changes to a data-plane path update assumptions and verify the relevant bound.

## Provider streaming

| Dimension | Envelope |
|---|---|
| Request duration | 600,000 ms default provider deadline |
| OpenAI-compatible retained output | Profile maximum, 10,000,000 bytes default |
| OpenCode retained output | 10,000,000 bytes schema default; production may override |
| Text frame batch | 16 frames per Agent persistence batch |
| Text chunk target | 8,192 bytes |
| Text flush latency | 50 ms |
| Provider rounds | 16 per Invocation |

Design intent: network latency dominates. Buffer short text to reduce event transactions while flushing within interactive latency. Output caps bound binary retention and parsing.

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
| Room/message/turn retention | Entire durable history retained in Projection |
| TUI render input | Current full Projection, presentation windows selected during rendering |
| Terminal dimensions | Runtime terminal size; tests include 50x20 through 160x32 |

The total Projection has no retention bound. Before long-lived multi-user operation, choose one of archival, pagination/windowed projection, or explicit memory/database capacity limits.

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
