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
| Provider rounds | No local count quota; each request remains byte/token bounded |
| Attempts per ProviderRound | 3 total; retry waits 1,000 ms then 3,000 ms |

Design intent: network latency dominates. Buffer short text to reduce event transactions while flushing within interactive latency. Output caps bound binary retention and parsing.

Reasoning deltas share the text chunk byte and latency limits. Pending reasoning
flushes even during transport silence; batches carry their segment's first frame
sequence so the transcript joins them without repeating the growing prefix in
each durable event. The existing provider activity retention bound still applies.

Historical provider activity remains readable, bounded to the newest 256 events
per Invocation. New model API calls return text and ToolCalls; tool activity is
recorded through ReyCode's durable ToolRun lifecycle.

### Provider context maintenance

OpenAI-compatible preflight encodes the same body as the first stream attempt.
It adds no network request and retains only that bounded request body until the
assessment returns. At 80 percent of either request budget, one maintenance pass
first replaces eligible earlier Session Messages with a bounded extractive
summary, then canonicalizes at most 64 complete old ProviderRounds and writes one
Invocation summary event of at most 32,768 bytes. It rebuilds the request and
reassesses toward 60 percent after every event. Session boundaries stop before
the earliest current input of any nonterminal Turn. Additional Invocation passes
strictly advance their boundary, so their count is bounded by the finite retained
round list. If no source remains, either byte or estimated-token overflow fails
before transport; maintenance-only pressure may proceed.

Network traffic is unchanged. Storage adds at most one bounded event per pass;
all original events remain under the existing unbounded database-retention policy.
The Projection already retains complete Invocation history, while reduction builds
one ToolCall-to-ToolRun index and handles at most 64 source rounds per pass rather
than rescanning all ToolRuns per call. The Agent Loop performs no provider stream
until the rebuilt request has been assessed. Tests cover no-preflight adapters,
maintenance with no eligible prefix, hard-limit recovery, exact OpenAI encoding,
multi-pass advancement, durable event ordering, and adapter-fault containment.

### ProviderRound recovery

Each request adds one bounded attempt event before network dispatch. A safe retry
adds one bounded schedule event and no network traffic during its 1,000 ms or
3,000 ms wait. Attempt count, wait duration, failure text (4,096 bytes), request
metrics, and retained frame output are bounded. A late frame, observed buffered
output, started ToolRun, or dispatched timeout terminates automatic retry rather
than issuing an uncertain duplicate request. Restart work is proportional to the
one projected current attempt; historical attempts remain ordinary Events under
the existing database-retention policy.

## Local engine transport

| Dimension | Envelope |
|---|---|
| Attached terminal clients | 32 per engine |
| Engine IPC workers | 64 concurrent, supervised |
| Pending calls | 32 per server peer; 64 per client connection |
| Uncompressed wire packet | 67,108,864 bytes |
| Normal projection/catalog polling | 100 ms, versioned; no command replay |
| Connection handshake | 5,000 ms per attempt |
| Detached startup polling | 30,000 ms plus the final bounded connection attempt |
| Default command deadline | 4,500 ms; catalog waits 20,000 ms; cancel/merge 30,000 ms |
| Headless verification deadline | Owner timeout plus 5,000 ms, at most 3,605,000 ms |
| Scoped resource hubs | 128; unborrowed idle hubs reclaimed at capacity |

Provider chunks are persisted before acknowledgement; a remote terminal can add
one polling interval plus IPC/rendering work to their visibility. Large histories
must fit the wire bound; this is not a paginated or multi-user network API.

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
| TUI reasoning previews visible | 8 logical previews per message behind a `+k earlier thoughts` collapse; previews wrap by terminal-cell width |
| Terminal dimensions | Runtime terminal size; tests include 50x20 through 160x32 |

The total Projection has no retention bound. Before long-lived multi-user operation, choose one of archival, pagination/windowed projection, or explicit memory/database capacity limits.

### Interactive redraw work

Root-view invalidations share Breeze's existing 16 ms input-render cadence.
Queued Projection notifications mark one pending root redraw; input is still
processed in order, and routing changes force a render before the next input
boundary. This coalesces display work, not Events or Projection processing.
The server regression drives twenty Projection updates through the actual Breeze
server and permits at most two root redraws rather than twenty.

Transcript Markdown, Mermaid expansion and cell wrapping are cached by displayed
body and effective width in BackBreeze's existing prepared-content cache. Stable
message IDs and selection highlighting are applied after retrieval. The cache
shares the renderer's 32-entry / 64 MiB serialized-value retention limits;
source-body keys also retain their source binaries. Eviction recomputes formatting
without clipping text. Layout still processes the full transcript.

Resource sketch: normal remote updates arrive at up to ten polls/second, with
provider and input bursts handled by the existing event loops. Display scheduling
reuses one timer/token and adds at most the remaining 16 ms cadence before render
work when the server is available. No extra network traffic or storage writes
are introduced. CPU work on cache misses remains proportional to the body;
cache hits reuse formatting, while layout and cache lookup/copy still scale with
the displayed transcript. No hard end-to-end latency bound is claimed.

Local macOS measurement at 120x32, with 500 repeated Markdown code sections:
ten warmed arrow-key-plus-redraw samples fell from 231–258 ms to 115–137 ms
with formatting reuse. These are diagnostic samples, not CI timing thresholds.
Tests cover burst redraw counts, navigation over long responses, fresh streamed
text, width changes, cross-message cache reuse and selection isolation.

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
