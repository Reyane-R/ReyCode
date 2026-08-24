# AGENTS.md

ReyCode is a terminal-native orchestration harness: rooms of humans and AI
agents with durable event-sourced history and ReyCode-owned tool execution.
Code lives in `lib/rey_code/`; tests mirror it under `test/` with a `_test.exs`
suffix.

## Read first

- [`docs/README.md`](docs/README.md) — the documentation index. Start here; it
  maps every doc to its audience and gives the reading order. Follow its
  pointers rather than reading everything.
- [`CONTEXT.md`](CONTEXT.md) — canonical domain glossary. When you meet a term
  you don't recognize (Turn, Invocation, Seat, Gate, Projection), look it up
  here before guessing from code. Introducing a concept means defining it here
  (`docs/standards/ONTOLOGY.md`).
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — guided code tour, including
  the "5 files to read first" (§3) and "where to find things" (§7).
- [`CODING_STANDARD.MD`](CODING_STANDARD.MD) — normative engineering rules.
  Read it before writing code; it points to the focused `docs/standards/`
  references.

## Verify before finishing

`mix check` is the gate and must pass: format check, compile with warnings as
errors, `credo --strict`, and the full test suite. Keep it green:

```sh
mix check
mix coverage                      # total coverage must stay above the 75% floor
MIX_ENV=dev mix dialyzer
mix test test/orchestration_engine_test.exs:120   # one test, fast feedback
```

The suite includes guardian tests (`test/quality/`) that fail when production
code violates project invariants, and property tests (`test/property/`) for the
security boundaries. CI enforces per-function CRAP scores against a committed
ratchet baseline (`quality/crap-baseline.json`) — never regenerate it to
silence a regression; that requires a genuine improvement.

## Invariants

- **Event sourcing.** Every state change is an event appended to the
  single-writer SQLite store — no UPDATE/DELETE of business data. The Projector
  is a pure event→state function; the projection is the source of truth.
- **Fail closed.** Durability or security uncertainty fails closed. External
  failures return tagged tuples (`{:error, reason}`); impossible internal
  states assert at the detection point.
- **Bounded everything.** Limits are explicit with units in the name
  (`_ms`, `_bytes`, `_count`). No unbounded waits, output, or recursion
  (`docs/standards/TIGER_STYLE.md`).
- **Terminology discipline.** Code uses Participant, Role, Seat,
  InvocationWorker, AgentLoop — "Agent" is user-facing prose only. Status ≠
  Outcome; Recommendation ≠ Resolution.
- **House rules are intentional**, enforced by custom credo checks: no
  `String.to_atom/1`, HTTP only via `:httpc` with a timeout, no bracket access
  on structs, no integer indexing of lists. Don't work around them.

## Docs are part of the code

- Hard-to-reverse trade-offs go in `DECISIONS.md` (active decisions up top,
  executed work in History).
- Engineering rules go in `CODING_STANDARD.MD`; domain meaning goes in
  `CONTEXT.md` — never both.
- User-facing behavior changes update the README.
