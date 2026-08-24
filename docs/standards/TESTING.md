# Testing Standard

## Observable contracts

Behavioral tests defend public contracts, invariants, transitions, fault models, and external boundaries. They do not assert private helper order, incidental layout, map iteration order, or source text.

Static architecture and source-policy tests MAY inspect source when a rule cannot be expressed through compilation, Credo, Dialyzer, or behavior. Such tests MUST defend a stable architecture or security invariant, not formatting or incidental syntax.

Examples of valid source-policy tests:

- Runtime modules do not read ambient application policy.
- External input does not create atoms.
- Forbidden process/HTTP dependencies are absent.
- Production sleeps remain in approved bounded modules.

## Required scenarios

Tests cover as applicable:

- Happy behavior.
- Boundary values.
- Invalid input.
- Stale and duplicate commands.
- Recovery after restart.
- Partial and interrupted work.
- Authorization denial.
- Timeout and resource exhaustion.
- Durable replay and compatibility.
- Actual UI/CLI behavior.

## Interfaces

- Prefer public interface tests.
- Test pure internal modules directly when they own substantial policy.
- Mocks belong at real seams.
- Use real serialization, persistence, and adapters in integration tests where practical.
- One fake adapter does not justify a production seam by itself.

## Determinism

- Tests are order-independent.
- Map order is never asserted.
- Time uses deadlines, injected clocks, bounded polling, or deterministic simulators.
- Fixed sleeps are not synchronization.
- Global state mutation is isolated and restored.
- Async tests do not share names, files, application policy, or environment variables.

## Property tests

Property tests are preferred for canonical paths, serialization, hashing, normalization, state-machine invariants, sequence continuity, bounded parsers, and replay equivalence. Each property states the invariant it proves.

## Coverage and complexity

- Coverage is evidence, not the objective.
- Every test fails for a plausible defect.
- Total coverage remains above the repository floor.
- Changed behavior has direct contract coverage.
- CRAP scores remain within the configured threshold.
- Baselines only decrease or disappear.

## Runtime proof

Permanent surface changes require runtime proof:

- TUI: launch, interact, observe rendered state.
- CLI: run the actual command and inspect output/status.
- Persistence: write, stop, restart, restore.
- Provider: execute a normalized round through an adapter or simulator.
- Tool: execute against an isolated workspace.

## Repository gates

```sh
mix check
mix coverage
MIX_ENV=test mix quality.crap \
  --lcov cover/lcov.info \
  --baseline quality/crap-baseline.json
MIX_ENV=dev mix dialyzer
```
