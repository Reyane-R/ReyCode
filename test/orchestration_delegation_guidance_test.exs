defmodule ReyCode.Orchestration.DelegationGuidanceTest do
  @moduledoc """
  Deterministic plumbing for the primary assistant's delegation roster. These
  tests prove what the prompt contains, not that a live model will delegate.
  """

  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Delegation,
    Participant,
    Projection,
    Session,
    Turn,
    VerifiedChange,
    WorkingContract
  }

  alias ReyCode.Orchestration.Workflow.Direct

  @roster_header "Task agents available for delegation"
  @no_worker "No task agents are configured in this session."

  defp participant(name, kind, perspective \\ "work"),
    do: %Participant{id: String.downcase(name), name: name, perspective: perspective, kind: kind}

  defp primary_prompt(session) do
    [plan] = Direct.plan(session, %Turn{id: "t", participant_id: nil}, %Projection{})
    plan.system_prompt
  end

  test "primary prompt lists eligible task agents by exact name, sorted, with responsibilities" do
    session = %Session{
      id: "s",
      participants: [
        participant("Assistant", :primary, "coding"),
        participant("Nova", :task, "review changed contracts"),
        participant("Luna", :task, "run focused tests"),
        participant("Old", :legacy),
        participant("Twin", :task),
        participant("Twin", :task)
      ]
    }

    prompt = primary_prompt(session)
    assert prompt =~ @roster_header
    assert prompt =~ "- Luna: run focused tests\n- Nova: review changed contracts"
    refute prompt =~ "- Assistant"
    refute prompt =~ "- Old"
    refute prompt =~ "Twin"
    assert prompt =~ "spawn_tasks for independent subtasks"
    assert prompt =~ "Children cannot delegate further"
    assert prompt =~ WorkingContract.decision_memory()
    assert prompt == primary_prompt(session)
  end

  test "an empty roster says so instead of advertising delegation" do
    prompt = primary_prompt(%Session{id: "s", participants: [participant("Assistant", :primary)]})
    assert prompt =~ @no_worker
    refute prompt =~ @roster_header
  end

  test "roster is bounded in count and per-responsibility bytes" do
    workers = for i <- 1..20, do: participant("W#{String.pad_leading("#{i}", 2, "0")}", :task)
    long = participant("Long", :task, String.duplicate("é", 400))

    session = %Session{id: "s", participants: [participant("A", :primary) | [long | workers]]}
    guidance = Delegation.primary_guidance(session)

    assert guidance =~ "- Long: " <> String.duplicate("é", 120) <> "\n"
    assert guidance =~ "- W15: work\n(5 more task agents not listed)"
    refute guidance =~ "- W16"
    assert String.valid?(guidance)
  end

  test "delegated children and restricted workflows carry no roster" do
    task = participant("Luna", :task)
    session = %Session{id: "s", participants: [participant("A", :primary), task]}

    [delegated] = Direct.plan(session, %Turn{id: "d", participant_id: task.id}, %Projection{})

    [detached] =
      Direct.plan(
        session,
        %Turn{id: "x", participant_id: task.id, detached?: true, task: "Ship"},
        %Projection{}
      )

    child =
      Delegation.child_system_prompt(%Delegation.Plan{
        participant: task,
        brief: "Run tests",
        output_schema: nil,
        isolate?: false,
        shared_context: "",
        peer_names: [],
        detach?: false
      })

    verified = primary_prompt(%{session | verified_change: %VerifiedChange{}})

    for prompt <- [delegated.system_prompt, detached.system_prompt, child, verified] do
      refute prompt =~ @roster_header
      refute prompt =~ @no_worker
      refute prompt =~ "spawn_task"
    end
  end
end
