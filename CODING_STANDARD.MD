# ReyCode Coding Standard

This is the normative engineering standard for ReyCode.

Read specialized references when the change touches that concern:

- Domain terms or state machines: [`CONTEXT.md`](CONTEXT.md) and [`docs/standards/ONTOLOGY.md`](docs/standards/ONTOLOGY.md)
- Limits, waits, allocation, dependencies, or performance: [`docs/standards/TIGER_STYLE.md`](docs/standards/TIGER_STYLE.md)
- Tests or runtime proof: [`docs/standards/TESTING.md`](docs/standards/TESTING.md)
- Data-plane design: [`docs/standards/PERFORMANCE.md`](docs/standards/PERFORMANCE.md)
- Review: [`docs/standards/REVIEW_CHECKLIST.md`](docs/standards/REVIEW_CHECKLIST.md)

## Normative language and priority

**MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative.

When rules conflict:

1. Correctness and durable data integrity.
2. Security and fail-closed behavior.
3. Recoverability and operational safety.
4. External compatibility and explicit contracts.
5. Bounded performance and resource use.
6. Domain and ontology integrity.
7. Interface depth and maintainability.
8. Local readability and style.

Idiomatic Elixir/OTP governs language mechanics. TigerStyle is adapted through `docs/standards/TIGER_STYLE.md`, not copied literally.

---

# 1. Core rules

## Correctness

- Implement complete behavior; never suppress only the symptom.
- Fix the invariant or transition that admitted a bug.
- Expected external failures return explicit tagged errors.
- Impossible internal states fail where detected.
- Durability or security uncertainty fails closed.
- Silent data loss, truncation, and fallback are prohibited.
- Compatibility behavior lives at the compatibility seam and names the historical format.

## Invalid states

- Stable domain records use typed structs.
- Open external payloads may use maps at wire seams.
- Decoded maps normalize into structs before normal execution.
- State transitions accept only valid source states.
- IDs, statuses, outcomes, phases, and authorities use validated known values.
- External strings never create atoms dynamically. (Enforced by the custom `StringToAtom` credo check in `credo_checks/`.)

## Deep modules

- A module owns one coherent responsibility.
- Its interface hides representation, ordering mechanics, and internal policy.
- Callers learn few functions and few facts.
- Pass-through modules without translation or policy are removed.
- New seams require real variation, security/durability ownership, or substantial hidden behavior.
- One adapter is hypothetical variation; two real adapters establish a seam.
- Depth matters more than file length.

Deletion test: if deleting a module spreads its complexity across callers, it is deep. If complexity disappears, it was shallow.

## One source of truth

- Every rule, default, mapping, invariant, and vocabulary definition has one authority.
- Derived indexes state their derivation and consistency rule.
- Defaults are declared once and injected.
- Conversion between internal and wire values occurs at one seam.
- Documentation explains non-obvious reasons rather than caching discoverable configuration.

## Clean cutovers

- Migrations update every caller.
- Obsolete functions, aliases, branches, and comments are removed.
- Compatibility shims remain only for external contracts.
- Temporary migration code has a removal condition.
- Durable compatibility is tested before readers or writers are removed.

---

# 2. Names and ontology

`CONTEXT.md` is authoritative.

- One term has one meaning in the orchestration context.
- Different meanings use different terms.
- Modules and records use nouns.
- Functions use verbs or verb phrases.
- Predicates end in `?`.
- Raising peers use `!` where failure behavior is not otherwise obvious.
- Units appear in names: `_ms`, `_bytes`, `_count`, `_limit`, `_index`, `_sequence`.
- Related names are symmetric: source/target, before/after, requested/completed.
- Abbreviations are avoided unless domain-standard.
- IDs use `<concept>_id` and identify exactly that concept.
- Role and Seat, Status and Outcome, Recommendation and Resolution, logical actor and worker process remain distinct.

Avoid generic domain names such as manager, service, helper, processor, data, info, and result when a precise term exists.

Ontology changes follow `docs/standards/ONTOLOGY.md` and update `CONTEXT.md` immediately.

---

# 3. Functions and modules

## One thing

A function does one thing when its body remains at one abstraction level and has one reason to change.

- Public functions express policy or a complete operation.
- Private functions hide a named decision, transformation, or side-effect sequence.
- A function answers a question or performs a command; mixtures require explicit semantics.
- Side effects are visible from name, interface, or owning module.
- Boolean flags become distinct functions, commands, or domain options.
- Distinct policies live behind named functions.
- Pattern matching, guards, and `with` flatten control flow where clearer.
- Functions are not split solely for line count.

## Parameters

- Prefer zero to four parameters.
- Five or six require coherent justification.
- Seven or more are prohibited.
- Repeated groups become real domain or policy records.
- A record must not exist merely to conceal arity.
- Dependencies are injected.
- Required values do not hide in untyped keyword lists.

For pipelines, the transformed value is normally the first parameter.

## Abstraction levels

- Read from intent to detail.
- Domain policy is separate from transport, serialization, persistence, and rendering.
- Wire construction lives at wire seams.
- Persistence mechanics live at persistence seams.
- Rendering lives in render modules.
- Process routing lives in process shells.
- State transitions live in transition modules.

## Duplication and abstraction

- Remove semantic duplication.
- Repeated syntax alone does not justify abstraction.
- An abstraction centralizes a rule that would otherwise diverge.
- Intentionally different rules remain separate and name the distinction.
- Small literal duplication is preferable to speculative flexibility.

## Cohesion

- Public functions operate on the same conceptual state.
- Modules that change for unrelated product reasons split at a natural seam.
- Process modules own lifecycle and routing; ordinary modules own pure policy.
- Large cohesive reducers and parsers may remain large.
- File length triggers review but is not a verdict.

---

# 4. Data and errors

## Internal and wire data

- Stable internal records are structs with concrete types.
- Wire/event/checkpoint maps are explicit and string-keyed where required.
- Struct field access uses dot syntax.
- Struct bracket access is prohibited. (Enforced by the custom `StructBracketAccess` and `ListBracketAccess` credo checks in `credo_checks/`.)
- HTTP is performed only through `:httpc` and every call passes a `:timeout`. (Enforced by the custom `ForbiddenHttpClients` and `RequireHttpTimeout` credo checks in `credo_checks/`.)
- Generic map fallbacks exist only at open-data or compatibility seams.
- Behavior belonging to a lifecycle is not distributed across arbitrary callers.
- Physical storage representation does not leak through deep interfaces.

## Failure classification

### Expected external failure

Return a tagged result:

```elixir
{:error, :invalid_tool_run_transition}
```

### Internal invariant failure

Assert, pattern-match, or raise:

```elixir
%Invocation{status: :running} = invocation
```

### Durability or security failure

Fail closed while preserving diagnostic context.

Additional rules:

- Failures identify operation and stable category.
- Retryability is explicit where callers retry.
- Catch-all rescue is limited to foreign seams and converts to a safe category.
- Exceptions do not replace ordinary validation.
- Cleanup uses ownership, supervision, `after`, or explicit release.
- Durable operations do not leave indeterminate state unless indeterminacy is recorded.
- Internal failures use the canonical Failure type and convert to maps only at wire seams.

---

# 5. Elixir and OTP

## Pattern matching

- Patterns state structural preconditions.
- Guards contain cheap type/value constraints.
- Externally caused match failures are validated or wrapped in tagged results.
- Internal invariant matches fail immediately.
- Complex guards become named predicates.

## Tagged results and bang functions

- Expected failures use `{:ok, value}` / `{:error, reason}`.
- Bang functions are for bootstrap, fail-stop durability, or invariant-preserving operations where the caller cannot safely recover.
- Raising behavior is documented.

## Pipelines

- Pipelines transform one primary value.
- They do not hide unrelated side effects.
- Frequent reshaping or `then/2` indicates named statements are clearer.
- Intermediate values with domain meaning are named.

## Processes

- GenServer interfaces document call/cast semantics, timeout, and ownership.
- Callbacks route to ordinary modules.
- Process state and mailboxes are bounded or admission-controlled.
- `GenServer.call` timeouts are intentional.
- Infinite and indirectly bounded waits follow `docs/standards/TIGER_STYLE.md`.
- Monitors and links have cleanup behavior.
- Process dictionary state is not used for durable or cross-task behavior.

## Supervision

- Fail-stop assertions occur below the correct restart seam.
- Supervisors restart the smallest safely reconstructable state.
- Restart loops are bounded or observable.
- Irreversible external ownership is not blindly restarted.
- Recovery derives from durable state.

## Tasks and concurrency

- Task counts are bounded.
- Concurrent work has an owner, deadline, cancellation path, and result contract.
- Work does not outlive its owner unless supervised.
- Tests do not depend on scheduler timing.
- `Process.sleep` is not synchronization except in approved simulator/test timing paths.

## Binaries and iodata

- Incremental output uses iodata.
- Data-plane loops avoid repeated concatenation.
- Retained binary size is bounded.
- UTF-8 boundaries are preserved during truncation.
- Text-only tools explicitly reject binary input.

## Configuration

- External policy may be flat for deployment compatibility.
- Internal policy is focused and immutable.
- Consumers receive only required policy; coordinators may compose several.
- Defaults and validation live in one schema.
- Runtime modules do not read ambient application policy.
- Credentials may be resolved at invocation time when rotatable and never persisted.

## Specs and documentation

- Public domain functions SHOULD have useful specs.
- Deep durable/security/process/adapter interfaces MUST document fault models.
- Internal implementation modules may use `@moduledoc false` when a parent owns the interface.
- Stable shapes use domain types rather than generic map/term specs.

---

# 6. Comments and formatting

- Comments explain invariants, ordering, atomicity, compatibility, security, or non-obvious performance choices.
- Comments do not narrate syntax.
- Obsolete and commented-out code is deleted.
- TODO/FIXME/HACK requires an issue, owner, or removal condition.
- `mix format` is authoritative.
- Manual alignment that fights the formatter is prohibited.
- Related declarations are grouped.
- Public interfaces precede implementation details.

---

# 7. Boundaries and composition

- Foreign data validates and normalizes at entry.
- Wrappers translate real contracts or fault models.
- Adapters convert foreign errors to stable internal failures.
- Provider, process, filesystem, database, environment, and TUI mechanics do not leak into orchestration policy.
- Tests cross the same interface as production callers.
- Startup assembles validated dependencies before work begins.
- Long-lived processes receive frozen policy.
- Construction is separate from use.
- Cross-cutting behavior lives at an explicit seam.

---

# 8. Design and refinement

A healthy design:

1. Passes tests.
2. Reveals intent.
3. Removes semantic duplication.
4. Uses the fewest concepts preserving depth and correctness.

Workflow:

1. Make contract and invariant explicit.
2. Implement the smallest complete behavior.
3. Prove behavior.
4. Refactor.
5. Remove scaffolding.

Blocking smells include rigidity, fragility, immobility, viscosity, needless complexity, semantic repetition, opacity, feature envy, shotgun surgery, primitive obsession, flag arguments, dead compatibility paths, generic internal error maps, and process modules containing pure policy.

---

# 9. Security and durability

- Resolve canonical filesystem identity before authorization.
- Enforce trusted roots after symlink resolution.
- Traversal results are revalidated.
- File and directory operations are bounded.
- Unknown tools fail closed.
- Approval-required tools perform no side effect before approval.
- Decisions bind to stable ToolRun IDs.
- Completed ToolRuns are reused, not replayed.
- Running ToolRuns found after restart fail as indeterminate.
- Child environments are allowlisted.
- Process timeout cancels the process tree.
- Atomic state transitions share one transaction.
- Expected projection sequence guards competing writers.
- Events persist before terminal state is reported.
- Checkpoints validate version, size, checksum, and shape.
- Secrets never enter events, projections, logs, diagnostics, fixtures, or errors.

---

# 10. Change workflow

## Before editing

1. Identify the domain concept and owning module.
2. Read `CONTEXT.md` and relevant decisions.
3. Find all callers of exported interfaces.
4. Identify durability, security, and compatibility seams.
5. State behavior, invariants, limits, and fault model.
6. Reuse existing conventions.

Done when every affected caller, durable representation, and contract test is known.

## During implementation

1. Change the owner, not a caller symptom.
2. Validate external input at the seam.
3. Preserve or migrate durable formats explicitly.
4. Migrate every caller in one cutover.
5. Remove obsolete paths.
6. Keep process shells thin and pure policies ordinary.
7. Add tests only for observable uncovered contracts.

Done when one representation and one active interface remain.

## Verification

Follow `docs/standards/TESTING.md` and run the changed surface itself.

Done when:

- Tests pass.
- Credo has no issues.
- Dialyzer has no errors or skips.
- Coverage passes.
- CRAP has no offenders.
- Runtime smoke proves behavior.
- No scaffolding or temporary files remain.

## Review order

1. Domain and ontology.
2. Durable and security invariants.
3. Fault model and bounds.
4. Interface depth.
5. Performance envelope.
6. Tests and recovery.
7. Names, comments, formatting.

Use `docs/standards/REVIEW_CHECKLIST.md`.

---

# 11. Exceptions and evolution

- Exceptions state reason, scope, risk, and removal condition.
- Framework convention is insufficient without interface and fault-model analysis.
- Performance claims require measurements or budgets.
- Future flexibility requires a real second adapter or scenario.
- Hard-to-reverse surprising trade-offs belong in `DECISIONS.md` or an ADR.
- New quality tooling requires a real failure existing gates could not catch.
- This standard changes when operational evidence invalidates a rule.

# References

- Robert C. Martin, *Clean Code*.
- [TigerStyle](https://tigerstyle.dev/).
- [NASA Power of Ten](https://spinroot.com/gerard/pdf/P10.pdf).
- [Erlang/OTP Design Principles](https://www.erlang.org/doc/system/design_principles.html).
