# ReyCode Coding Standard

This document is the normative engineering standard for ReyCode. It combines:

- Applicable practices from Robert C. Martin's *Clean Code*.
- An Elixir/OTP adaptation of TigerBeetle's TigerStyle.
- A framework for maintaining a precise, durable domain ontology.

The standard applies to production code, tests, migrations, tools, release code, and technical documentation.

## Normative language

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative.

When rules conflict, use this order:

1. Correctness and durable data integrity.
2. Security and fail-closed behavior.
3. Recoverability and operational safety.
4. External compatibility and explicit contracts.
5. Bounded performance and resource use.
6. Domain-model and ontology integrity.
7. Interface depth and maintainability.
8. Local readability and style.

Idiomatic Elixir/OTP takes precedence over language-specific advice written for C, Zig, Java, or C++ unless this document explicitly adopts that advice.

---

# 1. Core engineering rules

## 1.1 Correctness before convenience

- Code MUST implement the complete behavior, not suppress its symptom.
- A bug fix MUST repair the invariant or transition that admitted the bug.
- Expected external failures MUST be returned explicitly.
- Impossible internal states MUST fail at their point of detection.
- Durability or security uncertainty MUST fail closed.
- Silent data loss, silent truncation, and silent fallback are prohibited.
- A compatibility fallback MUST identify the historical format it supports and MUST live at the compatibility seam.

## 1.2 Make invalid states difficult to represent

- Stable domain records MUST use structs with concrete types.
- Open-ended external payloads MAY use maps at wire seams.
- Decoded maps MUST be normalized into internal structs before normal execution.
- State transitions MUST accept only their valid source states.
- IDs, statuses, outcomes, phases, decisions, and authorities MUST use validated known values.
- Arbitrary external strings MUST NOT be converted into atoms.

## 1.3 Deep modules

A module is deep when callers receive substantial behavior through a small interface.

- A module MUST own one coherent responsibility.
- Its interface MUST hide implementation details, ordering mechanics, and representation choices.
- A caller SHOULD need few functions and few facts to use the module correctly.
- Pass-through modules that merely rename another interface SHOULD be removed.
- A new seam requires actual variation, a security boundary, a durability boundary, or a substantial body of hidden policy.
- One adapter is usually hypothetical flexibility; two real adapters establish a real seam.
- Module depth matters more than file length.

Deletion test: if deleting a module merely moves the same complexity into every caller, it is earning its place. If deletion makes complexity disappear, it was probably shallow.

## 1.4 One source of truth

- Each rule, default, mapping, invariant, or vocabulary definition MUST have one authoritative location.
- Derived indexes MAY duplicate data only when their derivation and consistency rule are explicit.
- Defaults MUST be declared once and injected.
- Wire values MUST be converted in one direction at one seam.
- Comments and documentation MUST NOT copy facts that are directly discoverable from configuration unless the copy explains a non-obvious reason or constraint.

## 1.5 Clean cutovers

- A completed migration MUST update every caller.
- Obsolete functions, aliases, branches, fallback formats, and comments MUST be removed.
- Long-lived compatibility shims are prohibited unless an external contract requires them.
- Temporary migration code MUST have an explicit removal condition.
- Durable compatibility MUST be tested before old readers or writers are removed.

---

# 2. Clean Code practices

## 2.1 Names reveal intent

Names MUST explain what a thing is, what it does, or what invariant it represents.

- Modules and data types use nouns: `ToolRun`, `Projection`, `Workspace`.
- Functions use verbs or verb phrases: `resolve_gate`, `record_round`, `normalize_snapshot`.
- Predicates end in `?`: `terminal?`, `replayable?`, `allowed?`.
- Functions that intentionally raise use `!` when a non-raising peer exists or raising is not already obvious.
- Unit-bearing values use suffixes such as `_ms`, `_bytes`, `_count`, `_limit`, `_index`, and `_sequence`.
- Qualifiers follow the primary concept where practical: `timeout_ms`, `output_max_bytes`, `turn_id`.
- Related opposing names SHOULD be symmetric: `source`/`target`, `before`/`after`, `requested`/`completed`.
- Abbreviations SHOULD be avoided unless they are domain-standard and unambiguous.
- One term MUST have one meaning within a context.
- Different meanings MUST use different terms.

Avoid names such as `data`, `info`, `manager`, `helper`, `processor`, `thing`, `value`, or `result` when a more precise domain name exists.

## 2.2 Functions do one thing

A function does one thing when its body remains at one abstraction level and has one reason to change.

- Public functions SHOULD express policy or a complete operation.
- Private functions SHOULD hide a named decision, transformation, or side-effect sequence.
- A function SHOULD either answer a question or perform a command; surprising mixtures require justification.
- Side effects MUST be visible from the function name, interface, or owning module.
- Boolean flag parameters SHOULD be replaced by distinct functions, commands, or options with domain names.
- Branches that express distinct policies SHOULD move behind named functions.
- Nested control flow SHOULD be flattened with pattern matching, guards, `with`, or early tagged returns when that improves clarity.
- A function MUST NOT be split solely to satisfy a line-count target.

There is no fixed function-length limit. Review the abstraction level, branching, and interface instead.

## 2.3 Function parameters

- Prefer zero to four parameters.
- Five or six parameters require a coherent explanation.
- Seven or more parameters are prohibited.
- Repeated parameter groups MUST become a struct or focused policy.
- A struct MUST represent a real concept, not merely conceal excessive arity.
- Dependencies MUST be injected rather than created inside domain logic.
- Options MUST use domain names and validated values.
- Required values SHOULD NOT be hidden inside an untyped keyword list.

For pipelines, the primary transformed value SHOULD be the first parameter unless an established library convention requires otherwise.

## 2.4 Abstraction levels

- A function SHOULD read from high-level intent to lower-level detail.
- Domain policy MUST NOT be interleaved with transport, serialization, or UI mechanics.
- Wire construction belongs at wire seams.
- Persistence mechanics belong at persistence seams.
- Rendering belongs in render modules.
- Process routing belongs in process shells.
- State transition logic belongs in transition modules.

## 2.5 Duplication

- Semantic duplication MUST be removed.
- Repeated syntax alone is not sufficient reason to create an abstraction.
- An abstraction MUST centralize a rule that would otherwise diverge.
- Two similar branches that intentionally encode different rules SHOULD remain separate and document the distinction.
- Small literal duplication is preferable to a shallow or speculative abstraction.

## 2.6 Modules and cohesion

- A module MUST have one coherent responsibility.
- Public functions SHOULD operate on the same conceptual state.
- A module that changes for unrelated product reasons MUST be split at the natural seam.
- A process module SHOULD own process lifecycle and message routing, while pure policy lives in ordinary modules.
- A large cohesive reducer or parser MAY remain large.
- File length is evidence for review, not a verdict.

## 2.7 Data structures and behavior

- Stable internal records MUST be typed structs.
- Behavior belonging to a record's lifecycle SHOULD live with its transition module, not be distributed across arbitrary callers.
- Wire maps MUST be string-keyed when required by external formats.
- Internal code MUST use atom fields and struct field access.
- Struct bracket access is prohibited.
- Generic `Map.get/3` fallbacks are allowed only at open-data or compatibility seams.
- Callers MUST NOT know the physical storage representation of a deep module.

## 2.8 Error handling

Classify failures before choosing a mechanism.

### External or expected failure

Return a tagged error:

```elixir
{:error, :invalid_tool_run_transition}
```

### Internal invariant failure

Use a pattern match, assertion, or explicit exception:

```elixir
%Invocation{status: :running} = invocation
```

### Durability or security failure

Fail closed and preserve diagnostic context:

```elixir
raise DurableCheckpointError, reason: reason
```

Additional rules:

- Errors MUST identify the failing operation and stable category.
- Retryability MUST be explicit where callers retry.
- Catch-all rescue is prohibited unless it converts a foreign fault at a seam and preserves a safe error category.
- Exceptions MUST NOT be used for ordinary input validation.
- `nil`, empty collections, and sentinel atoms MUST not represent unrelated failure modes.
- Cleanup MUST happen with `after`, ownership, supervision, or an explicit release path.
- A failure path MUST not leave a durable record in an indeterminate state unless that indeterminacy is itself recorded.

## 2.9 Comments

Comments explain why, not what the syntax already states.

Good comments document:

- Invariants.
- Ordering requirements.
- Atomicity requirements.
- Compatibility constraints.
- Security decisions.
- Non-obvious performance trade-offs.
- Why an apparently simpler implementation is unsafe.

Comments MUST be updated with code. Obsolete, commented-out, redundant, or misleading comments MUST be deleted. Version control owns deleted code.

`TODO`, `FIXME`, and `HACK` comments require an issue reference, owner, or concrete removal condition. Prefer completing the work immediately.

## 2.10 Formatting

- `mix format` is authoritative.
- Manual alignment that fights the formatter is prohibited.
- Related declarations SHOULD be grouped.
- Aliases and attributes MUST follow repository and Credo ordering.
- Blank lines separate concepts, not individual statements mechanically.
- A file SHOULD present its interface before implementation details.

## 2.11 Boundaries

- Foreign data MUST be validated and normalized at entry.
- External modules MUST be wrapped only when the wrapper translates a real contract or fault model.
- Adapters MUST convert foreign errors into stable internal errors.
- Provider, process, filesystem, database, environment, and TUI framework details MUST not leak into orchestration policy.
- Tests SHOULD cross the same interface as production callers.

## 2.12 Systems and composition

- Startup MUST assemble validated dependencies before serving work.
- Long-lived processes MUST receive frozen configuration.
- Runtime modules MUST not read ambient application configuration directly.
- Bootstrap code MAY read application configuration and environment variables.
- A system MUST separate construction from use.
- Cross-cutting behavior such as logging, authorization, or retries MUST live at an explicit seam rather than be scattered.

## 2.13 Emergent design

A design is healthy when it:

1. Passes all tests.
2. Reveals intent.
3. Removes semantic duplication.
4. Uses the fewest concepts that still preserve depth and correctness.

Refactoring MUST keep behavior green or deliberately change a tested contract. Do not introduce abstraction for hypothetical future variation.

## 2.14 Successive refinement

- First make the contract and invariant explicit.
- Implement the smallest complete behavior.
- Refactor after behavior is proven.
- Remove scaffolding before completion.
- A prototype intended for deletion MUST be visibly isolated and MUST not enter production paths.

## 2.15 Code smells that block approval

The following require correction or explicit justification:

- Rigidity: one change forces unrelated edits.
- Fragility: local changes break distant behavior.
- Immobility: useful logic cannot be reused without unrelated dependencies.
- Viscosity: the incorrect change is easier than the correct one.
- Needless complexity: speculative seams, strategies, factories, or configuration.
- Needless repetition: the same rule exists in multiple locations.
- Opacity: names or flow conceal intent.
- Feature envy: a module knows another record's representation better than its owner.
- Shotgun surgery: one domain rule is spread across many callers.
- Primitive obsession: stable domain concepts remain anonymous strings or maps.
- Flag arguments: one function secretly implements multiple operations.
- Dead code or compatibility paths without a live contract.
- Generic error maps constructed throughout the implementation.
- Process modules containing large bodies of pure policy.

---

# 3. Elixir and OTP practices

## 3.1 Pattern matching and guards

- Use pattern matching to state structural preconditions.
- Use guards for cheap type and value constraints.
- Pattern matches that can fail because of external input MUST be preceded by validation or wrapped in a tagged result.
- Pattern matches for internal invariants SHOULD fail immediately.
- Complex guard logic SHOULD become a named predicate.

## 3.2 Tagged results and bang functions

- Expected failures use `{:ok, value}` / `{:error, reason}`.
- A bang function is appropriate for bootstrap, fail-stop durability, or an invariant-preserving operation where recovery is impossible at that layer.
- Every bang function MUST make the failure domain clear in its documentation or name.

## 3.3 Pipelines

- Pipelines SHOULD express a sequence of transformations on one primary value.
- A pipeline MUST NOT hide unrelated side effects.
- A pipeline with frequent argument reshaping or `then/2` steps SHOULD be rewritten as named statements.
- Intermediate variables SHOULD be named when they carry domain meaning.

## 3.4 Processes

- A GenServer interface MUST describe call/cast semantics, timeout behavior, and ownership.
- GenServer callbacks SHOULD route to ordinary modules.
- Process state MUST be bounded or protected by admission control.
- Every `GenServer.call/3` MUST have an intentional timeout; `:infinity` requires a documented invariant or durable operation that cannot safely time out.
- Mailbox growth MUST be considered for every externally reachable process.
- Monitors and links MUST have explicit cleanup behavior.
- Process dictionary state is prohibited for durable or cross-task behavior.

## 3.5 Supervision

- Assertions and fail-stop exceptions MUST occur below the correct restart seam.
- Supervisors MUST restart the smallest state that can be reconstructed safely.
- Restart loops MUST be bounded by policy or made observable.
- A process that owns irreversible external state MUST not be blindly restarted.
- Recovery MUST derive from durable state rather than stale process memory.

## 3.6 Tasks and concurrency

- Task counts MUST be bounded.
- Concurrent work MUST have an owner, timeout, cancellation path, and result contract.
- Background work MUST not outlive the resource or request that owns it unless explicitly supervised.
- Tests MUST not depend on scheduler timing.
- `Process.sleep/1` is not synchronization except in intentional simulator/test timing modules.

## 3.7 Binaries and iodata

- Use iodata for incremental output construction.
- Avoid repeated binary concatenation in data-plane loops.
- Retained binary size MUST be bounded.
- UTF-8 boundaries MUST be preserved when truncating text.
- Binary payloads MUST be rejected or handled explicitly by text-only tools.

## 3.8 Atoms

- External data MUST NOT create atoms dynamically.
- Use known lookup tables, validated IDs, or `String.to_existing_atom/1` only when the atom is guaranteed to exist.
- Durable wire formats SHOULD store stable strings and normalize them through known mappings.

## 3.9 Configuration

- External configuration MAY be flat for deployment compatibility.
- Internal configuration MUST be assembled into focused immutable policies.
- Consumers receive only the policy they need.
- Coordinators MAY receive the top-level policy when they deliberately compose multiple concerns.
- Default values and validation live in one schema.
- Runtime modules MUST not call `Application.get_env/3` or read policy environment variables.
- Credentials MAY be read at invocation time when they must remain rotatable and are never persisted.

## 3.10 Specs and module documentation

- Public domain functions SHOULD have `@spec` declarations.
- Deep modules MUST document their interface, fault model, and important ordering constraints.
- Internal implementation modules MAY use `@moduledoc false` when their parent module owns the interface.
- Specs SHOULD name domain types rather than generic `map()` or `term()` where the shape is stable.

---

# 4. TigerStyle-ReyCode profile

TigerStyle's values are Safety, Performance, and Experience. ReyCode adopts their intent with BEAM-compatible rules.

## 4.1 Safety

### Explicit limits

Everything that can grow or wait MUST have a bound.

Bound at minimum:

- Request duration.
- Provider output bytes.
- Tool stdout and stderr bytes.
- File bytes and lines.
- Match, result, and directory-entry counts.
- Queue length.
- Active concurrency.
- Replay events.
- Checkpoint bytes and interval.
- Retries, rounds, cycles, and rework.
- Diagnostics retained.
- Background refresh duration.

For each limit, define:

1. Unit.
2. Default.
3. Valid range.
4. Owner policy.
5. Behavior at the limit.
6. Error category.
7. Whether retry is safe.

Limits MUST live in the focused policy that owns the resource.

### Runtime assertions

Types check shape; assertions check logic.

Assert:

- Arguments after external validation.
- State-machine source states.
- Contiguous sequences.
- Monotonic counters.
- Durable append expectations.
- Return values from internal callbacks.
- Positive and negative invariants.

An assertion MUST distinguish programmer error from external failure. Assertions MUST NOT replace user input validation.

### Fault models

Every deep interface MUST define its fault model:

- What can fail.
- How failure is represented.
- What state may already be durable.
- Whether the operation is idempotent.
- Whether retry is safe.
- How cancellation works.
- Which supervisor owns recovery.

### Logical interfaces

- Minimize interface surface.
- Prefer deterministic logical operations over exposing nondeterministic physical mechanics.
- Push control flow up and data flow down.
- Callers choose what operation occurs; modules own how it is performed safely.

### Dimensionality

- Return the smallest type that expresses the answer.
- Prefer explicit enums/statuses over overloaded integers or strings.
- Use unit-bearing names.
- Define variables near use.
- Avoid interfaces whose options create branches at every caller.

### Allocation: BEAM adaptation

Literal static allocation is not adopted. ReyCode uses bounded allocation:

- Bounded queues and mailboxes through admission.
- Bounded process and task counts.
- Bounded binaries and buffers.
- Bounded ETS state.
- Bounded replay and projection work.
- Bounded retained diagnostics and output.

Manual object pools for ordinary immutable data SHOULD NOT be introduced without measurements.

### Recursion: BEAM adaptation

Tail recursion is allowed. Recursive work MUST have one of:

- A visible decreasing counter.
- A bounded input collection.
- An upstream byte/count cap.
- Ownership by an OTP event loop.

Unbounded recursion over external input is prohibited.

### Dependencies: dependency budget

Literal zero dependencies is not adopted.

A new production dependency requires documented answers:

1. What substantial implementation and risk does it replace?
2. What is its maintenance and release health?
3. What security and supply-chain exposure does it add?
4. What runtime cost does it add?
5. How difficult is removal?
6. Can the standard library satisfy the requirement safely?

Framework, SQLite, process, and JSON dependencies are acceptable when they eliminate larger, riskier implementations.

### Technical debt

- Known broken invariants MUST be fixed before adding adjacent behavior.
- Temporary shortcuts require a concrete removal condition.
- Quality baselines may only improve.
- A deadline is not permission to weaken data integrity or security.
- Scope discipline still applies: unrelated redesign is not required to complete a safe change.

## 4.2 Performance

### Performance sketches

Before changing a data-plane design, write a back-of-the-envelope sketch covering:

| Resource | Bandwidth questions | Latency questions |
|---|---|---|
| Network | Bytes/request, frames/second | First byte, total deadline |
| Storage | Events/turn, checkpoint bytes | Append, transaction, restore |
| Memory | Retained projection, buffers | Allocation/GC pressure |
| Compute | Parsing, hashing, rendering | Per-event/per-frame CPU |

The sketch MAY be approximate. It MUST state assumptions and order of magnitude.

### Control plane and data plane

- The control plane validates, authorizes, schedules, and asserts.
- The data plane streams, batches, stores, and transforms bounded payloads.
- High-frequency data-plane work SHOULD be batched.
- Control-plane convenience MUST not force per-item data-plane overhead.
- Batching MUST preserve durability and cancellation semantics.

Examples:

- Provider frames are batched before persistence.
- Events append transactionally.
- Checkpoints amortize replay.
- Tool output is collected under byte caps.

### Direct data movement

Literal zero-copy is not required. Apply these rules:

- Avoid avoidable serialization inside one process boundary.
- Pass binaries without rebuilding them where possible.
- Use iodata for output.
- Avoid converting the same payload repeatedly.
- Strip structs only at durable/wire seams.
- Measure before introducing complex zero-copy techniques.

### Background scheduling

- Periodic maintenance SHOULD use fixed intervals with bounded work.
- Interactive input, provider frames, and process exits remain event-driven.
- A timer MUST have cancellation and duplicate-scheduling semantics.
- Retries MUST use bounded delay and attempt count.

## 4.3 Experience

### Simplicity and elegance

- Prefer the smallest complete design.
- Prefer standard library and OTP behavior over custom infrastructure.
- Optimize total ownership cost, not initial typing speed.
- A difficult design problem SHOULD be resolved before implementation spreads it across callers.

### Nouns and verbs

- Use nouns for records and modules.
- Use verbs for operations.
- Put the most significant concept first where that matches Elixir conventions.
- Preserve symmetry among related names.
- Avoid abbreviations.
- Domain vocabulary overrides generic framework vocabulary.

### Source rhythm

- Keep public interface together.
- Keep related transition clauses together.
- Use consistent clause order: valid/specific cases before general fallbacks.
- Keep error paths visually explicit.
- Prefer boring, repeatable structure over clever syntax.

## 4.4 TigerStyle rules not adopted literally

The following are intentionally translated rather than copied:

- Allocate all memory at startup.
- Ban recursion.
- Ban event-driven behavior.
- Use fixed-width integers for all internal values.
- Have zero dependencies.
- Require zero-copy across process and persistence seams.
- Replace OTP supervision with manual recovery.

Any proposal to adopt one literally requires an ADR with measurements and failure analysis.

---

# 5. Ontology framework

Ontology is the project's shared model of what exists, how concepts relate, and which transitions are valid. It is not a naming cleanup performed after implementation.

## 5.1 Sources of truth

- `CONTEXT.md` is the canonical domain glossary when present.
- `CONTEXT.md` contains domain meaning only, not implementation details.
- Typed records and interface names MUST agree with the glossary.
- Event names and payloads MUST agree with the glossary.
- `DECISIONS.md` records hard-to-reverse implementation and architecture decisions, not term definitions.
- README prose MUST use canonical terms.

Until `CONTEXT.md` is introduced, the canonical vocabulary in this document applies.

## 5.2 Concept categories

Every important term SHOULD be classified as one of:

- **Entity**: has stable identity across change.
- **Value**: defined by its contents.
- **Event**: immutable fact that happened.
- **Command**: request to attempt a transition.
- **Policy**: rules controlling choices or limits.
- **Actor**: entity or role with authority to initiate decisions.
- **Role**: stable responsibility definition.
- **Assignment/Seat**: binding of a role to an execution capability.
- **State**: current lifecycle position.
- **Outcome**: result of a completed lifecycle.
- **Projection**: derived read model.
- **Adapter**: implementation satisfying an interface at a seam.

Do not use one type for multiple categories merely because the fields are similar.

## 5.3 Ontology design process

When adding or changing a domain concept:

1. **Scenarios**: write concrete happy, failure, recovery, stale, duplicate, and concurrent scenarios.
2. **Terms**: name each actor, entity, value, event, command, policy, state, and outcome.
3. **Definitions**: define each term in one sentence without implementation language.
4. **Identity**: state whether it has an ID and what the ID identifies.
5. **Ownership**: identify which concept owns its lifecycle.
6. **Relationships**: state cardinality and direction.
7. **State machine**: enumerate valid states and transitions.
8. **Invariants**: define what must always and never be true.
9. **Authority**: identify who may request and who may resolve each decision.
10. **Events**: name durable facts in past tense.
11. **Wire mapping**: define internal types versus external representations.
12. **Compatibility**: define how historical values normalize.
13. **Tests**: encode transitions, invariants, replay, and stale/duplicate scenarios.
14. **Glossary**: update the canonical term immediately after resolution.

The concept is complete only when code, tests, events, and glossary use the same meaning.

## 5.4 Terminology rules

- One term has one meaning within the orchestration context.
- Synonyms MUST be collapsed to one canonical term.
- Homonyms MUST be split into precise terms.
- IDs use `<concept>_id` and identify exactly that concept.
- State and outcome MUST be different concepts when both are stored.
- Recommendation and authoritative decision MUST have different names.
- Role and assignment MUST have different names.
- Logical actors and worker processes MUST have different names.
- Domain names MUST not inherit vague framework terms such as `manager`, `handler`, or `service`.
- Historical names MAY remain at compatibility seams but MUST be marked legacy and normalized immediately.

## 5.5 Relationship rules

For every relationship, answer:

- One-to-one, one-to-many, or many-to-many?
- Which side owns creation?
- Which side owns deletion or terminal state?
- Can either side exist independently?
- Is the relationship durable or derived?
- What ID is stored?
- What happens if the target is stale or missing?

A relationship implied only by map nesting is incomplete ontology.

## 5.6 State-machine rules

- Valid states MUST be enumerated.
- Every transition MUST name source state, command, event, destination state, and failure behavior.
- Terminal states MUST be explicit.
- Idempotent transitions MUST define duplicate behavior.
- Restart recovery MUST define treatment of in-flight states.
- `status` describes lifecycle position.
- `outcome` describes a completed result.
- A record MUST NOT carry redundant status and outcome values without a documented invariant.
- Transition validation belongs in one module.

## 5.7 Event ontology

- Event names are past-tense facts: `turn_started`, `tool_run_completed`.
- Commands are imperative requests: `post_message`, `cancel_turn`.
- An event payload MUST identify its entity and correlation context.
- Event schema versions and historical aliases MUST be explicit.
- Events are immutable after persistence.
- Projectors MUST be deterministic and side-effect-free.
- Unknown durable values MUST fail closed or enter an explicit compatibility path.
- Legacy events MUST normalize into current concepts at replay seams.

## 5.8 Internal and wire models

- Internal stable concepts use structs.
- Wire/event/checkpoint payloads use explicit map representations.
- Conversion occurs once at the seam.
- Struct tags MUST not leak into durable payloads unless the durable protocol explicitly specifies them.
- Historical maps normalize recursively before normal execution.
- Internal modules MUST not depend on string-keyed wire maps.

## 5.9 Authority model

Every decision MUST distinguish:

- Requester.
- Recommender.
- Reviewer.
- Authority.
- Resolution.

Automated recommendation MUST NOT be represented as authoritative human resolution. Stale reviews MUST be rejected by stable review identity.

## 5.10 Ontology review questions

A change is not ready when any answer is unclear:

- What new thing exists after this change?
- Is it an entity, value, event, command, policy, actor, state, or outcome?
- Does its name already mean something else?
- What owns it?
- What is its lifecycle?
- What are its valid transitions?
- What is impossible?
- Who has authority over it?
- What is durable and what is derived?
- How does it serialize?
- How do old values normalize?
- Which tests prove the ontology rather than the implementation?

---

# 6. ReyCode canonical vocabulary

These definitions are normative. Code migrations may lag temporarily, but new code MUST use the canonical meaning.

| Term | Meaning |
|---|---|
| Workspace | Canonical filesystem directory in which a Room's work is scoped. |
| WorkspacePolicy | Trusted roots and containment rules governing workspace access. |
| Room | Durable workspace-rooted conversation containing participants, messages, and ordered turns. |
| Operator | Human supplying ordinary room input. |
| Owner | Human authority for tool approvals and human-controlled release decisions. |
| Participant | Configured logical actor available to a room's non-squad workflows. |
| Turn | One durable orchestration request initiated by a user message. |
| TurnStatus | Lifecycle position of a turn. |
| TurnOutcome | Result of a terminal turn. |
| Invocation | One durable provider execution for a participant or squad seat within a turn. |
| InvocationWorker | Supervised process executing one invocation. |
| AgentLoop | Provider/tool continuation algorithm for an invocation. |
| ProviderRound | One normalized provider response containing text, tool calls, and usage. |
| ToolCall | Provider request to invoke a named tool with arguments. |
| ToolRun | Durable authorization and execution lifecycle for one ToolCall. |
| Event | Immutable durable fact. |
| EventStore | Ordered transactional storage of events and projection checkpoints. |
| Projector | Pure deterministic event-to-projection transition module. |
| Projection | Current typed read model derived from events/checkpoints. |
| ProviderRegistry | Static definitions of supported provider identities and adapters. |
| ProviderProfile | Configuration of one API-compatible provider identity. |
| ProviderCatalog | Transient discovery, readiness, model availability, and runtime resolution. |
| ProviderRuntime | Frozen invocation-time adapter capability and focused policy. |
| Role | Stable squad responsibility definition. |
| Seat | Assignment of a Role to a provider/model capability in a room. |
| SquadRun | Leader-supervised workflow state attached to a squad turn. |
| Phase | Stable named state in a SquadRun workflow. |
| PhaseIndex | Internal ordered cursor locating a Phase. |
| Artifact | Durable output claimed for a phase and role. |
| GateRecommendation | Automated leader recommendation at a gate. |
| GateReview | Pending obligation requiring the configured authority's action. |
| GateResolution | Authoritative decision that resolves a GateReview. |
| ReleaseAuthority | Policy selecting Owner or Squad Leader as release resolver. |
| Failure | Internal typed description of category, message, retryability, and optional cause. |

## 6.1 Terms to use precisely

### Agent

Use a qualified term:

- Participant for a configured logical actor.
- Role for a squad responsibility.
- Seat for a configured squad assignment.
- InvocationWorker for the supervised process.
- AgentLoop for the continuation algorithm.

The unqualified word `agent` is acceptable in user-facing prose only when the distinction is irrelevant.

### Phase and stage

- Phase is the domain concept.
- PhaseIndex is its internal numeric position.
- `stage` SHOULD NOT be introduced as a synonym for either.

### Gate concepts

- Recommendation is advisory.
- Review is pending work.
- Resolution is authoritative and terminal for that review.

### Status and outcome

- Status is lifecycle position.
- Outcome is terminal result.
- A field named `status` MUST not sometimes contain outcomes unless that combined model is explicitly documented and used consistently.

---

# 7. Testing standard

## 7.1 Test observable behavior

Tests MUST defend contracts, invariants, transitions, boundaries, or fault models.

Good tests cover:

- Happy behavior.
- Boundary values.
- Invalid input.
- Stale and duplicate commands.
- Recovery after restart.
- Partial and interrupted work.
- Authorization denial.
- Timeout and resource exhaustion.
- Durable replay and compatibility.
- Actual UI/CLI behavior where applicable.

Tests MUST NOT assert source text, private helper order, incidental map iteration order, or implementation-only call sequences unless those are the interface.

## 7.2 Test through interfaces

- Prefer public interface tests.
- Test pure internal modules directly when they own a substantial policy.
- Mocks belong at real seams.
- A mock for a dependency that never varies indicates a speculative seam.
- Use real serialization, persistence, and adapters in integration tests where practical.

## 7.3 Determinism

- Tests MUST be deterministic and order-independent.
- Map iteration order MUST not be asserted.
- Time MUST be controlled by deadlines, injected clocks, polling with bounds, or deterministic simulators.
- Fixed sleeps are prohibited as synchronization.
- Global state mutation requires isolation and restoration.
- Async tests MUST not share process names, files, application configuration, or environment variables.

## 7.4 Property tests

Property tests SHOULD cover:

- Path canonicalization and containment.
- Serialization round trips.
- Hashing and normalization.
- State-machine invariants.
- Sequence continuity.
- Bounded parsers.
- Replay equivalence.

A property test MUST state the invariant it proves.

## 7.5 Coverage and complexity

- Coverage is evidence, not the goal.
- Every test must fail for a plausible implementation defect.
- Total coverage MUST remain above the repository floor.
- Changed behavior SHOULD have direct contract coverage.
- Per-function CRAP scores MUST remain within the configured threshold.
- Baselines may only decrease or disappear.
- Complexity SHOULD be reduced rather than hidden behind untested functions.

## 7.6 Runtime smoke tests

Permanent changes to these surfaces require runtime proof:

- TUI: launch, interact, and observe rendered state.
- CLI: run the actual command and inspect output/status.
- Persistence: write, stop, restart, and restore.
- Provider: execute at least one normalized round through an adapter or deterministic simulator.
- Tools: execute the changed operation against an isolated workspace.

---

# 8. Security and durability

## 8.1 Workspace and filesystem

- Resolve canonical identity before authorization.
- Enforce trusted roots after symlink resolution.
- Reject filesystem roots as workspaces.
- Revalidate result paths produced by traversal.
- File reads/writes and directory traversal MUST be bounded.
- Binary/text behavior MUST be explicit.

## 8.2 Tool execution

- Unknown tools fail closed.
- Approval-required tools MUST perform no side effect before approval.
- Decisions bind to stable ToolRun IDs.
- Completed ToolRuns MUST be reused, not replayed.
- Running ToolRuns found after restart are indeterminate and MUST fail closed.
- Environment variables passed to child processes MUST be allowlisted.
- Timeout cancellation MUST terminate the process tree.

## 8.3 Event durability

- Related state transitions requiring atomicity MUST share one transaction.
- Expected projection sequence MUST guard against competing writers.
- Events persist before terminal state is reported.
- Checkpoint failure semantics MUST preserve recoverability.
- Checkpoint and legacy decoding MUST validate version, size, checksum, and shape.
- Replay MUST be deterministic.

## 8.4 Secrets

- Secrets MUST not enter events, projections, logs, diagnostics, fixtures, or error messages.
- Credentials SHOULD be resolved at invocation time.
- Environment snapshots MUST pass through allowlists.
- Tests use sentinel secrets and assert they do not appear in output.

---

# 9. Performance and resource checklist

For every loop, queue, process, buffer, and external operation, reviewers verify:

- [ ] Maximum work is explicit.
- [ ] Maximum retained memory is explicit.
- [ ] Maximum duration is explicit.
- [ ] Maximum concurrency is explicit.
- [ ] Cancellation is defined.
- [ ] Retry count and delay are bounded.
- [ ] Truncation is reported.
- [ ] Units are present in names.
- [ ] Overflow or invalid range is rejected at the wire/configuration seam.
- [ ] High-frequency work is batched where safe.
- [ ] No repeated serialization or copying is avoidable.
- [ ] The failure at each bound is tested.

---

# 10. Change workflow

## 10.1 Before editing

1. Identify the domain concept and owning module.
2. Read the canonical glossary and relevant decisions.
3. Find every caller of exported interfaces.
4. Identify durability, security, and compatibility seams.
5. State the behavior and invariant being changed.
6. Identify resource limits and fault model.
7. Reuse existing conventions.

Completion criterion: every affected caller, durable representation, and contract test is known.

## 10.2 During implementation

1. Change the owning source, not a symptom at a caller.
2. Keep external input validation at the seam.
3. Preserve or explicitly migrate durable formats.
4. Migrate all callers in one clean cutover.
5. Remove obsolete paths.
6. Keep process shells thin.
7. Keep policies pure when they do not require I/O.
8. Add tests only for observable uncovered contracts.

Completion criterion: one representation and one active interface remain.

## 10.3 Verification

Run the repository gates:

```sh
mix check
mix coverage
MIX_ENV=test mix quality.crap \
  --lcov cover/lcov.info \
  --baseline quality/crap-baseline.json
MIX_ENV=dev mix dialyzer
```

Then run the changed surface itself.

Completion criterion:

- All tests pass.
- Credo reports no issues.
- Dialyzer reports no errors or skips.
- Coverage remains above the floor.
- CRAP reports no offenders.
- Runtime smoke proves the changed behavior.
- Worktree contains no scaffolding, temporary files, or obsolete compatibility code.

## 10.4 Review

Review in this order:

1. Domain and ontology correctness.
2. Durable and security invariants.
3. Fault model and bound behavior.
4. Interface depth and caller burden.
5. Performance envelope.
6. Tests and recovery.
7. Naming, comments, and formatting.

---

# 11. Pull request checklist

## Domain

- [ ] New terms have one-sentence definitions.
- [ ] Existing terms keep their canonical meaning.
- [ ] Entity/value/event/command/policy/state/outcome categories are clear.
- [ ] Ownership, identity, relationships, and authority are explicit.
- [ ] State transitions and terminal behavior are tested.

## Clean Code

- [ ] Names reveal intent and units.
- [ ] Modules have one coherent responsibility.
- [ ] Interfaces are small and deep.
- [ ] Functions remain at one abstraction level.
- [ ] Arity is six or less and preferably four or less.
- [ ] No semantic duplication or speculative abstraction was added.
- [ ] Comments explain invariants or reasons.
- [ ] Obsolete code and migration paths are removed.

## TigerStyle safety

- [ ] Every resource and wait is bounded.
- [ ] Fault models and retryability are explicit.
- [ ] Internal impossible states assert or fail-stop.
- [ ] External failures return tagged errors.
- [ ] Durability/security uncertainty fails closed.
- [ ] Recursion has a visible bound.
- [ ] Dependencies and allocation costs are justified.

## Performance

- [ ] Data-plane changes include a back-of-the-envelope sketch.
- [ ] Batching and copying choices are intentional.
- [ ] Memory, storage, network, and compute costs are bounded.
- [ ] No optimization weakens correctness or readability without measurements.

## Verification

- [ ] Contract tests cover new behavior and limits.
- [ ] Replay/restart compatibility is tested when durable state changes.
- [ ] Actual TUI/CLI/provider/tool surface was exercised where applicable.
- [ ] `mix check` passes.
- [ ] Coverage passes.
- [ ] Dialyzer passes without skips.
- [ ] CRAP has no offenders or baseline regressions.

---

# 12. Exceptions and evolution

- An exception requires a concrete engineering reason, affected scope, risk, and removal condition.
- "Framework convention" is not sufficient without checking the actual interface and fault model.
- "Performance" is not sufficient without measurements or an explicit budget.
- "Future flexibility" is not sufficient without a second real adapter or scenario.
- Hard-to-reverse, surprising decisions with genuine alternatives SHOULD be recorded in `DECISIONS.md` or a future ADR.
- New quality tooling is added only after a real failure demonstrates that existing gates would not detect the problem.
- This document MUST evolve when code, ontology, or operational evidence invalidates a rule.

---

# References

- Robert C. Martin, *Clean Code: A Handbook of Agile Software Craftsmanship*.
- TigerBeetle, [TigerStyle](https://tigerstyle.dev/).
- Gerard J. Holzmann, [The Power of 10: Rules for Developing Safety-Critical Code](https://spinroot.com/gerard/pdf/P10.pdf).
- Erlang/OTP, [Design Principles](https://www.erlang.org/doc/system/design_principles.html).
