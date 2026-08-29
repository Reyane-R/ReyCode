defmodule ReyCode.Orchestration.WorkingContractTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Delegation,
    Participant,
    Projection,
    Session,
    Turn,
    WorkingContract
  }

  alias ReyCode.Orchestration.Workflow.Direct

  test "primary and explicitly delegated coding prompts carry one traceability contract" do
    primary = %Participant{
      id: "assistant",
      name: "Assistant",
      perspective: "coding assistance",
      kind: :primary
    }

    task = %Participant{
      id: "luna",
      name: "Luna",
      perspective: "database work",
      kind: :task
    }

    session = %Session{id: "session", participants: [primary, task]}

    [primary_plan] =
      Direct.plan(session, %Turn{id: "direct", participant_id: nil}, %Projection{})

    [task_plan] =
      Direct.plan(session, %Turn{id: "task", participant_id: task.id}, %Projection{})

    [detached_plan] =
      Direct.plan(
        session,
        %Turn{id: "detached", participant_id: task.id, detached?: true, task: "Ship it"},
        %Projection{}
      )

    contract = WorkingContract.decision_memory()
    assert primary_plan.system_prompt =~ contract
    assert task_plan.system_prompt =~ contract
    assert detached_plan.system_prompt =~ "Detached task:\nShip it"
    assert detached_plan.system_prompt =~ contract
    assert contract =~ "ask_operator"
    assert contract =~ "kind=assumption"
    assert contract =~ "DECISIONS.md"
  end

  test "delegation child prompt carries the same contract exactly once" do
    participant = %Participant{
      id: "luna",
      name: "Luna",
      perspective: "database work",
      kind: :task
    }

    plan = %Delegation.Plan{
      participant: participant,
      brief: "Choose a storage layout",
      output_schema: nil,
      isolate?: false,
      shared_context: "",
      peer_names: [],
      detach?: false
    }

    prompt = Delegation.child_system_prompt(plan)
    contract = WorkingContract.decision_memory()
    assert prompt =~ contract
    assert length(:binary.matches(prompt, contract)) == 1
  end
end
