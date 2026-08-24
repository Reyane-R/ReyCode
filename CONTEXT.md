# ReyCode Domain Glossary

This file is the canonical glossary for ReyCode's orchestration context. It contains domain meaning only. Implementation and architecture decisions belong in `DECISIONS.md`; engineering rules belong in `CODING_STANDARD.MD`.

## Core conversation

**Workspace** — Canonical filesystem directory in which a Room's work is scoped.

**Room** — Durable workspace-rooted conversation containing participants, messages, and ordered turns.

**Operator** — Human supplying ordinary room input.

**Owner** — Human authority for tool approvals and owner-controlled release decisions.

**Participant** — Configured logical actor available to a Room's non-squad workflows.

**Message** — Durable communication authored by an Operator or produced by an Invocation.

**Turn** — One durable orchestration request initiated by an Operator message.

**TurnStatus** — Lifecycle position of a Turn: queued, running, or terminal.

**TurnOutcome** — Result of a terminal Turn: completed, partial, failed, cancelled, or reworked.

## Provider execution

**Invocation** — One durable provider execution for a Participant or Squad Seat within a Turn.

**InvocationWorker** — Supervised process executing one Invocation.

**AgentLoop** — Provider/tool continuation algorithm for an Invocation.

**ProviderRound** — One normalized provider response containing text, ToolCalls, and usage.

**ToolCall** — Provider request to invoke a named tool with arguments.

**ToolRun** — Durable authorization and execution lifecycle for one ToolCall.

**Failure** — Internal typed description of a failure category, message, retryability, and optional cause.

## Provider discovery

**ProviderRegistry** — Static definitions of supported provider identities and adapters.

**ProviderProfile** — Configuration of one API-compatible provider identity.

**ProviderCatalog** — Transient discovery, readiness, model availability, and runtime resolution.

**ProviderRuntime** — Frozen invocation-time adapter capability and focused policy.

## Squad workflow

**Role** — Stable squad responsibility definition.

**Seat** — Assignment of a Role to a provider/model capability in a Room.

**SquadRun** — Leader-supervised workflow state attached to a squad Turn.

**Phase** — Stable named state in a SquadRun workflow.

**PhaseIndex** — Internal ordered cursor locating a Phase.

**Cycle** — Number of times work has entered or repeated a Phase.

**Artifact** — Durable output claimed for a Phase and Role.

**GateRecommendation** — Automated Squad Leader recommendation at a gate.

**GateReview** — Pending obligation requiring the configured authority's action.

**GateResolution** — Authoritative decision resolving a GateReview or automated gate.

**ReleaseAuthority** — Policy selecting Owner or Squad Leader as release resolver.

**Squad Leader** — Automated Role responsible for recommendations, automated gate resolutions, and targeted rework.

## Durability and read models

**Event** — Immutable durable fact recorded in past tense.

**EventStore** — Ordered transactional storage of Events and Projection checkpoints.

**Projector** — Pure deterministic Event-to-Projection transition module.

**Projection** — Current typed read model derived from Events and checkpoints.

**Checkpoint** — Durable map-based snapshot used to bound replay work.

## Relationships

- A Workspace contains zero or more Rooms.
- A Room owns ordered Messages and Turns.
- A Room has Participants and may have Squad Seats.
- A Turn belongs to one Room and may own multiple Invocations.
- An Invocation belongs to one Turn and one Participant or Seat.
- An Invocation owns ordered ProviderRounds and ToolRuns.
- A ToolRun realizes exactly one ToolCall.
- A squad Turn owns exactly one SquadRun.
- A SquadRun has one current Phase and PhaseIndex.
- A GateReview contains one GateRecommendation and is completed by one GateResolution.
- Events are projected deterministically into one Projection.

## Authority

- Operators may create Rooms, post Messages, and cancel their work.
- Owners resolve ToolRun approvals and owner-controlled release reviews.
- Squad Leaders may recommend or resolve gates according to ReleaseAuthority.
- Provider output never grants authority by itself; it requests transitions that ReyCode validates.

## Precise usage

**Agent** — Use only in user-facing prose where the distinction is irrelevant. Code uses Participant, Role, Seat, InvocationWorker, or AgentLoop.

**Phase and PhaseIndex** — Phase is the domain state; PhaseIndex is the internal numeric cursor. Stage is a legacy wire term only.

**Status and Outcome** — Status is lifecycle position. Outcome is the terminal result and is nil before termination.

**Recommendation, Review, Resolution** — Recommendation is advisory, Review is pending work, Resolution is authoritative.

## Legacy wire terms

The following terms may appear only at event/checkpoint compatibility seams:

- `stage` maps to PhaseIndex.
- `seat_id` maps to Role or Seat identity according to the event type.
- `tool_ask_*` events map to the current ToolRun approval model.

Legacy terms are normalized immediately and are not used by normal internal execution.
