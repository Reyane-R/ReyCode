# Ontology Standard

Ontology is the shared model of what exists, how concepts relate, and which transitions are valid. `CONTEXT.md` is the canonical glossary.

## Concept categories

Every important term is classified as one of:

- Entity: stable identity across change.
- Value: defined by contents.
- Event: immutable fact.
- Command: request to attempt a transition.
- Policy: rules controlling choices or limits.
- Actor: entity or role with authority.
- Role: stable responsibility.
- Seat: assignment of a role to capability.
- State: lifecycle position.
- Outcome: terminal result.
- Projection: derived read model.
- Adapter: implementation satisfying an interface at a seam.

One type MUST NOT represent multiple categories merely because fields are similar.

## Modeling process

For a new or changed concept:

1. Write happy, failure, stale, duplicate, concurrent, and recovery scenarios.
2. Name actors, entities, values, commands, events, policies, states, and outcomes.
3. Define each term in one sentence without implementation language.
4. State identity and what its ID identifies.
5. Identify lifecycle ownership.
6. Define relationship direction and cardinality.
7. Enumerate valid states and transitions.
8. Define positive and negative invariants.
9. Identify requester, recommender, reviewer, and authority.
10. Name durable facts in past tense.
11. Define internal and wire representations.
12. Define legacy normalization.
13. Test transitions, invariants, replay, and stale/duplicate behavior.
14. Update `CONTEXT.md` immediately.

A concept is complete only when glossary, code, tests, events, and UI use the same meaning.

## Terminology

- One term has one meaning within the orchestration context.
- Synonyms collapse to one canonical term.
- Homonyms split into precise terms.
- IDs use `<concept>_id` and identify exactly that concept.
- Status and outcome are distinct when both are stored.
- Recommendation and authoritative resolution have distinct names.
- Role and Seat are distinct.
- Logical actors and worker processes are distinct.
- Historical names are limited to compatibility seams and normalized immediately.

## Relationships

For every relationship, define:

- Cardinality.
- Creation owner.
- Deletion or terminal-state owner.
- Whether either side exists independently.
- Durable or derived nature.
- Stored ID.
- Missing/stale target behavior.

Map nesting alone is not a complete relationship definition.

## State machines

- Valid states are enumerated.
- Every transition names source state, command, event, destination state, and failure behavior.
- Terminal states are explicit.
- Duplicate/idempotent behavior is explicit.
- Restart recovery defines treatment of in-flight states.
- Status is lifecycle position.
- Outcome is terminal result and nil before termination.
- Transition validation lives in one module.

## Events

- Event names are past-tense facts.
- Commands are imperative requests.
- Event payloads identify entity and correlation context.
- Schema versions and historical aliases are explicit.
- Persisted events are immutable.
- Projectors are deterministic and side-effect-free.
- Unknown durable values fail closed or enter an explicit compatibility path.

## Internal and wire models

- Stable internal concepts use structs.
- Event, checkpoint, and foreign payloads use explicit map representations.
- Conversion occurs once at the seam.
- Struct tags do not leak into durable maps.
- Historical maps normalize recursively before normal execution.
- Internal modules do not depend on string-keyed wire maps.

## Authority

Every decision identifies:

- Requester.
- Recommender.
- Reviewer.
- Authority.
- Resolution.

Automated recommendations are never represented as human resolutions. Stale reviews are rejected by stable review identity.

## Review questions

- What new thing exists?
- Which category is it?
- Does its name already mean something else?
- What owns it?
- What is its lifecycle?
- Which transitions are valid?
- What is impossible?
- Who has authority?
- What is durable and what is derived?
- How is it serialized?
- How do old values normalize?
- Which tests prove the ontology rather than the implementation?
