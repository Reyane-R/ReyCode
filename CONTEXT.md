# ReyCode Domain Glossary

This file is the canonical glossary for ReyCode's orchestration context. It contains domain meaning only. Implementation and architecture decisions belong in `DECISIONS.md`; engineering rules belong in `CODING_STANDARD.MD`.

## Core conversation

**Workspace** — Canonical filesystem directory in which a Session's work is scoped.

**Session** — Durable user-visible conversation with one Workspace, agent profiles, Messages, and ordered Turns.

**SessionFork** — Session whose inherited transcript references completed Messages from one parent Session through a recorded durable sequence; later Messages belong only to the fork.

**Room** — Internal orchestration aggregate backing one Session. Never shown in the user interface.

**Operator** — Human supplying ordinary Session input.

**Owner** — Human authority for tool approvals and owner-controlled release decisions.

**Participant** — Configured logical actor available to a Session's non-squad workflows.

**Primary Participant** — The one Participant that receives ordinary Operator messages. Every Session has exactly one.

**Task Participant** — User-created Participant with a standing responsibility and independently selected provider/model. It runs only through explicit Delegation.

**Delegation** — A Turn explicitly addressed to one Task Participant for one task.

**Message** — Durable communication authored by an Operator or produced by an Invocation.

**DelegationContract** — Frozen optional JSON output schema and workspace-isolation choice for one delegated child Invocation.

**IsolationWorktree** — Temporary detached git worktree owned by one delegated child and either patch-applied on successful validation or removed without application.

**DelegationWave** — Bounded set of child Invocations opened atomically by one parent ToolRun from frozen shared context and ordered task contracts. Worker children enter admission together; an optional IntegrationOwner starts only after every worker is terminal; an attached parent resumes only after the full Wave is terminal.

**IntegrationOwner** — Task Participant designated in one DelegationWave to receive the worker reports after the worker barrier and produce the Wave's final integration report.

**PeerMessage** — Bounded durable message sent between active child Invocations in the same DelegationWave and included in the target's next ProviderRound context.

**DetachedDelegation** — Background Turn initiated by an Invocation and addressed to one Task Participant. The source Invocation receives a durable receipt immediately; the background Turn does not occupy the Session's active Turn slot, and its terminal Task Participant Message is delivered into the Session transcript.

**Turn** — One durable orchestration request initiated by an Operator message or by a DetachedDelegation from an Invocation.

**FollowUp** — Operator Turn queued behind existing Session work and cancellable before it starts.

**Steering** — Bounded durable Operator correction attached to one active Invocation and consumed at the next provider-round boundary.

**TurnStatus** — Lifecycle position of a Turn: queued, running, or terminal.

**TurnOutcome** — Result of a terminal Turn: completed, partial, failed, cancelled, or reworked.

**ContextBoundary** — Durable Session sequence through which earlier Messages are replaced by one ContextSummary in future provider requests; Events and transcript history remain unchanged.

**ContextSummary** — Bounded extractive conversation value recorded at a ContextBoundary.

## Provider execution

**Invocation** — One durable provider execution for a Participant or Squad Seat within a Turn.

**ProjectInstructions** — Bounded workspace instruction content frozen into an Invocation with its source paths and digest.

**BackgroundProcess** — Named bounded host process owned by ProcessHub, with supervised lifecycle and bounded retained output.

**InvocationWorker** — Supervised process executing one Invocation.

**AgentLoop** — Provider/tool continuation algorithm for an Invocation.

**ProviderRound** — One normalized provider response containing text, ToolCalls, and usage.

**ToolCall** — Provider request to invoke a named tool with arguments.

**ToolRun** — Durable authorization and execution lifecycle for one ToolCall.

**ToolAsk** — Pending owner decision recorded when a ToolRun execution needs approval, addressed by request id.

**OperatorQuestion** — Bounded durable question raised by an Invocation for the Operator, with two to five frozen options and at most one recommended option. It pauses only that Invocation until the Operator selects one option.

**WorkPlan** — Durable phased progress projection owned by one Invocation. Items have exactly one lifecycle status; after each update, at most one actionable item is in progress and the earliest pending item auto-promotes when none is running.

**PlanPhase** — Ordered named grouping inside a WorkPlan.

**PlanItem** — Uniquely named bounded unit of work inside one PlanPhase. Its status is pending, in progress, blocked, completed, or dropped.

**ModelTier** — Participant model-cost/capability designation: smol, default, or slow. The tier freezes a TokenBudget when an Invocation opens; it never changes that Invocation's provider/model identity.

**TokenBudget** — Maximum provider-reported token count admitted for one Invocation. Unknown usage remains unknown; once known usage reaches the budget, no further ProviderRound starts.

**spawn_task** — Orchestration tool a Provider sees in its tool definitions; the engine claims it and spawns one child Invocation addressed to an exact task Participant.

**Delegation (agent-initiated)** — Durable parent/child handoff via `spawn_task`: the parent Invocation suspends (`:awaiting_delegation`) with zero provider rounds until the child terminates; the child's report re-enters the parent conversation as the ToolRun result.

**Delegation depth** — Persisted per-Invocation count of delegation ancestors; 1 denies further `spawn_task` calls deterministically.

**Author** — Typed attribution of a Message to the Operator or the executing Participant or Seat.

**Failure** — Internal typed description of a failure category, message, retryability, and optional cause.

**GitReview** — Bounded Projection of repository status, diff checks, and prioritized whitespace findings before approved Git mutation.

**DebugSession** — Supervised DAP conversation with one debugger process for inspection and controlled execution.

**EvaluationKernel** — Supervised persistent Python or JavaScript process retaining one bounded namespace for approved code evaluation.

**ProjectMemory** — Append-only SQLite facts and lessons scoped to one Workspace.

**Advisor** — Opt-in Task Participant used for explicit advisory review; its output is a Recommendation, not an authoritative Resolution.

**AgentHub** — TUI projection and control surface for delegated child Invocations.

## Provider discovery

**ProviderRegistry** — Static definitions of supported provider identities and adapters.

**ProviderProfile** — Configuration of one API-compatible provider identity.

**ProviderCatalog** — Transient discovery, readiness, model availability, and runtime resolution.

**ProviderRuntime** — Frozen invocation-time adapter capability and focused policy.

## Squad workflow

**GitReview** — Bounded repository status, diff, conflict, and prioritized finding projection.

**DebugSession** — Supervised Debug Adapter Protocol conversation with one debugger process.

**EvaluationKernel** — Supervised persistent Python or JavaScript process retaining one bounded namespace.

**ProjectMemory** — Append-only SQLite facts and lessons scoped to one Workspace.

**Advisor** — Opt-in Task Participant whose output is a Recommendation, not an authoritative Resolution.

**AgentHub** — TUI projection and control surface for delegated child Invocations.


**Role** — Stable squad responsibility definition.

**Seat** — Assignment of a Role to a provider/model capability in a Room.

**SquadRun** — Leader-supervised workflow state attached to a squad Turn.

**Phase** — Stable named state in a SquadRun workflow.

**PhaseIndex** — Internal ordered cursor locating a Phase.

**Cycle** — Number of times work has entered or repeated a Phase.

**Artifact** — Durable output claimed for a Phase and Role.

**Retry** — Recorded provider retry or leader rework scheduled on a squad Turn.

**Directive** — Operator guidance recorded on a running squad Turn.

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

- A Workspace contains zero or more Sessions.
- Every Session is backed by one internal Room aggregate.
- A Session owns ordered Messages and Turns.
- A Session has exactly one Primary Participant, zero or more Task Participants, and may have Squad Seats.
- An ordinary Turn invokes only the Session's Primary Participant.
- A Delegation invokes exactly one Task Participant.
- An Invocation belongs to one Turn and one Participant or Seat.
- A Steering belongs to one active Invocation and is recorded into exactly one ProviderRound when consumed.
- A DelegationContract belongs to exactly one delegated child Invocation; its IsolationWorktree, when present, has the same owner.
- An Invocation owns ordered ProviderRounds and ToolRuns.
- A Session has at most one current ContextBoundary; later boundaries supersede it for provider-context reconstruction without deleting Events.
- A SessionFork has exactly one parent Session and one immutable fork sequence.
- A BackgroundProcess is owned by ProcessHub and does not outlive it.
- A ToolRun realizes exactly one ToolCall.
- A squad Turn owns exactly one SquadRun.
- A SquadRun has one current Phase and PhaseIndex.
- A GateReview contains one GateRecommendation and is completed by one GateResolution.
- Events are projected deterministically into one Projection.

## Authority

- Operators may create Sessions, create Task Participants, post Messages, delegate tasks, and cancel their work.
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
