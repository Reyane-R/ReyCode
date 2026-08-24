# TigerStyle-ReyCode

ReyCode adopts TigerStyle's values—Safety, Performance, and Experience—using Elixir/OTP-compatible rules. Correctness, data integrity, security, and recoverability outrank local convenience.

## Explicit limits

Everything that can grow or wait is bounded directly or transitively.

A bound is valid when termination is proved by one of:

1. A local timeout or count.
2. An owned outer deadline.
3. A monitored owner's finite lifecycle.
4. A finite input collection or byte budget.
5. An OTP event loop whose mailbox is protected by admission control.

Indirect bounds MUST be documented at the wait site.

Bound at minimum:

- Request and command duration.
- Provider and tool output bytes.
- File bytes and lines.
- Queue length and active concurrency.
- Replay events and checkpoint bytes.
- Retry, round, cycle, and rework counts.
- Diagnostics and retained buffers.
- Background refresh work.

Every limit defines unit, default, valid range, owner policy, limit behavior, error category, and retry safety.

## Infinity exceptions

`:infinity` is allowed only when timing out could leave a durable operation's commit status unknowable or when a monitored owner/deadline proves termination elsewhere.

An infinite wait MUST document:

- Why a finite timeout is less safe.
- Which process or durable operation owns completion.
- How cancellation occurs.
- Which supervisor handles failure.

Concurrency and queue policies MUST be finite in production. Tests or deliberately unsafe local modes MAY use `:infinity` when the mode is explicit.

## Assertions and failures

- External or environmental failures return tagged results.
- Impossible internal states assert, pattern-match, or raise at detection.
- Durability and security uncertainty fails closed.
- Assertions never replace input validation.
- Fail-stop assertions occur below a restart seam that can reconstruct state safely.

Each deep interface documents its fault model: failures, durability point, idempotency, timeout, retryability, cancellation, and recovery owner.

## Logical interfaces

- Minimize interface surface.
- Prefer deterministic logical operations over physical nondeterministic mechanics.
- Push control flow up and data flow down.
- Return the smallest type expressing the answer.
- Use units in names.
- Repeated parameter groups become real policy or domain records.

## BEAM allocation model

Literal static allocation is not used. ReyCode uses bounded allocation:

- Admission-controlled queues and mailboxes.
- Bounded process/task counts.
- Bounded binaries, buffers, ETS state, replay, and diagnostics.
- Focused immutable policies.

Object pools for ordinary immutable records require measurements.

## Recursion

Tail recursion is idiomatic. Recursive work requires a decreasing counter, bounded input, upstream byte/count cap, or OTP ownership. Unbounded recursion over external input is prohibited.

## Dependency budget

A new production dependency documents:

1. Substantial implementation and risk replaced.
2. Maintenance and release health.
3. Security and supply-chain exposure.
4. Runtime and installation cost.
5. Removal cost.
6. Why the standard library is insufficient.

Zero dependencies is not a literal goal.

## Control plane and data plane

The control plane validates, authorizes, schedules, and asserts. The data plane streams, batches, stores, and transforms bounded payloads.

- High-frequency data-plane work SHOULD be batched.
- Control-plane convenience MUST NOT impose per-item data-plane overhead.
- Batching preserves durability, order, and cancellation semantics.
- Repeated serialization or copying requires justification.
- Iodata is preferred for incremental output.

## Performance sketches

Data-plane changes include a back-of-the-envelope sketch for network, storage, memory, and compute, each considering bandwidth and latency. Approximate assumptions are acceptable; omitted dimensions are not.

See `docs/standards/PERFORMANCE.md` for current envelopes.

## Background scheduling

- Maintenance uses fixed intervals with bounded work where practical.
- Interactive input, provider frames, and process exits remain event-driven.
- Timers define cancellation and duplicate-scheduling behavior.
- Retries have bounded attempts and delay.

## Technical debt

- Broken invariants are fixed before adjacent behavior is added.
- Temporary shortcuts have removal conditions.
- Quality baselines only improve.
- Deadlines never justify weaker integrity or security.
- Scope discipline still applies; unrelated redesign is not mandatory.

## Naming and experience

- Nouns name records and modules; verbs name operations.
- Names include units and preserve symmetry.
- Abbreviations are avoided.
- Domain vocabulary from `CONTEXT.md` overrides generic framework terms.
- Public interfaces appear before implementation details.
- Error paths remain visually explicit.

## Rules intentionally not literal

ReyCode does not literally adopt:

- Allocate all memory at startup.
- Ban recursion.
- Ban event-driven behavior.
- Fixed-width integers for all internal values.
- Zero dependencies.
- Universal zero-copy.
- Manual recovery instead of OTP supervision.

Literal adoption of one of these requires an ADR with measurements and failure analysis.

## References

- [TigerStyle](https://tigerstyle.dev/)
- [NASA Power of Ten](https://spinroot.com/gerard/pdf/P10.pdf)
