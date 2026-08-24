# ReyCode Review Checklist

## Domain

- [ ] New terms are defined in `CONTEXT.md`.
- [ ] Existing terms retain one canonical meaning.
- [ ] Entity/value/event/command/policy/state/outcome categories are clear.
- [ ] Ownership, identity, relationships, and authority are explicit.
- [ ] State transitions and terminal behavior are tested.
- [ ] Legacy wire terms normalize at compatibility seams only.

## Clean Code

- [ ] Names reveal intent and units.
- [ ] Modules have one coherent responsibility.
- [ ] Interfaces are small and deep.
- [ ] Functions remain at one abstraction level.
- [ ] Arity is six or less and preferably four or less.
- [ ] No semantic duplication or speculative abstraction was added.
- [ ] Comments explain invariants or reasons.
- [ ] Obsolete paths were removed.

## TigerStyle safety

- [ ] Every resource and wait is directly or transitively bounded.
- [ ] Indirect and infinite waits document ownership and cancellation.
- [ ] Fault models and retryability are explicit.
- [ ] Internal impossible states assert or fail-stop.
- [ ] External failures return tagged errors.
- [ ] Durability/security uncertainty fails closed.
- [ ] Recursion has a visible bound.
- [ ] Dependency and allocation costs are justified.

## Performance

- [ ] Data-plane changes update `docs/standards/PERFORMANCE.md` or include a sketch.
- [ ] Batching and copying choices are intentional.
- [ ] Memory, storage, network, and compute are bounded.
- [ ] Optimization does not weaken correctness without measurements.

## Verification

- [ ] Contract tests cover behavior and limits.
- [ ] Architecture source tests defend stable policy, not incidental syntax.
- [ ] Replay/restart compatibility is tested for durable changes.
- [ ] Actual TUI/CLI/provider/tool surface was exercised where applicable.
- [ ] `mix check` passes.
- [ ] Coverage passes.
- [ ] Dialyzer passes without skips.
- [ ] CRAP has no offenders or baseline regressions.
