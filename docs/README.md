# ReyCode Documentation

A map of the docs in this repository: what each one is for, who it's written
for, and what to read when. If you're new here, follow the reading order below.

## If you're new here (especially if you don't know Elixir)

Read these three, in order. Everything else can wait.

| # | Doc | What it gives you |
|---|---|---|
| 1 | [`README.md`](../README.md) | What the app is, how to install and run it, keyboard shortcuts |
| 2 | [`ARCHITECTURE.md`](ARCHITECTURE.md) | A guided tour of the whole codebase, written for people who don't know Elixir. Follows one action — typing a message — end-to-end |
| 3 | [`CONTEXT.md`](../CONTEXT.md) | The domain glossary: what "Turn", "Invocation", "Seat", "Gate", "Projection" mean |

If you hit a term you don't recognize, look it up in `CONTEXT.md` rather than
guessing from code.

## Skip these until you're contributing

| Doc | What it is | Why to defer it |
|---|---|---|
| `DECISIONS.md` | The team's architectural decision log (D1–D24) | Written for the team: dense identifiers, PR/issue references, acceptance criteria. Read a specific decision when you want the recorded *why* behind a design |
| `Plan.md` | Delivery plan for the tool-execution layer | Status tracking for a finished delivery, not user-facing |
| `CODING_STANDARD.MD` | Normative engineering rules | Assumes you're writing Elixir in this repo |

## If you're writing code

Read `CODING_STANDARD.MD` first. It is the normative standard and points to
focused references:

| Doc | Concern |
|---|---|
| [`docs/standards/ONTOLOGY.md`](standards/ONTOLOGY.md) | Domain modeling: what exists, how concepts relate |
| [`docs/standards/TIGER_STYLE.md`](standards/TIGER_STYLE.md) | Limits, waits, allocation, and safety rules |
| [`docs/standards/TESTING.md`](standards/TESTING.md) | What tests must cover and how |
| [`docs/standards/PERFORMANCE.md`](standards/PERFORMANCE.md) | Design envelopes for data-plane paths |
| [`docs/standards/REVIEW_CHECKLIST.md`](standards/REVIEW_CHECKLIST.md) | The checklist used when reviewing changes |
