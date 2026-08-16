defmodule ReyCode.Orchestration.SquadWorkflowTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Workflow.Squad
  alias ReyCode.Orchestration.Workflow.Squad.Finalizer

  test "injects owner directives into every subsequently scheduled role" do
    roles = %{
      "gherkin_author" => participant("gherkin_author", "Gherkin Author"),
      "qa_author" => participant("qa_author", "QA Author")
    }

    room = %{squad_roles: roles}

    turn = %{
      id: "turn-1",
      invocation_order: [],
      squad: %{
        directives: [
          %{text: "Keep the first release read-only."},
          %{text: "Prioritize audit evidence over throughput."}
        ]
      }
    }

    context = %{room: room, turn: turn, projection: %{invocations: %{}}}
    specs = Squad.specs_for_phase(context, 4, 0)

    assert length(specs) == 2

    assert Enum.all?(specs, fn spec ->
             spec.system_prompt =~ "Owner directives that apply to this work:" and
               spec.system_prompt =~ "Keep the first release read-only." and
               spec.system_prompt =~ "Prioritize audit evidence over throughput."
           end)
  end

  test "finalizes valid squad output as terminal and artifact events" do
    invocation = invocation("analyst", "stories")

    message = %{
      body: ~s({"kind":"artifact","artifact_type":"stories","summary":"ready","blockers":[]})
    }

    assert {:advance, [completed, artifact]} =
             Squad.finalize(
               invocation,
               message,
               {:completed, %{usage: %{tokens: 12}}},
               human_release_review?: true
             )

    assert {:invocation_completed, %{"metadata" => %{"usage" => %{"tokens" => 12}}}, _} =
             completed

    assert {:squad_artifact_recorded,
            %{
              "kind" => "stories",
              "summary" => "ready",
              "digest" => digest
            }, _} = artifact

    assert is_binary(digest)
  end

  test "returns a declarative retry action for retryable squad failures" do
    invocation = invocation("analyst", "stories")
    error = %{"category" => "timeout", "retryable" => true}

    assert {:retry, [failed, retry], retry_spec} =
             Squad.finalize(invocation, %{body: ""}, {:failed, error},
               human_release_review?: true
             )

    assert {:invocation_failed, %{"error" => ^error}, _} = failed
    assert {:squad_retry_scheduled, %{"attempt" => 2, "reason" => "timeout"}, _} = retry
    assert retry_spec.attempt == 2
    assert retry_spec.logical_work_id == invocation.logical_work_id
  end

  test "turns invalid provider output into a retryable failure path" do
    invocation = invocation("analyst", "stories")
    message = %{body: "this is not json"}

    assert {:retry, [failed, retry], retry_spec} =
             Squad.finalize(invocation, message, {:completed, %{}}, human_release_review?: true)

    assert {:invocation_failed,
            %{"error" => %{"category" => "invalid_squad_output", "retryable" => true}}, _} =
             failed

    assert {:squad_retry_scheduled, %{"attempt" => 2, "reason" => "invalid_squad_output"}, _} =
             retry

    assert retry_spec.attempt == 2
  end

  test "delegates squad finalization to the pure finalizer" do
    invocation = invocation("analyst", "stories")
    message = %{body: "not json"}
    outcome = {:completed, %{usage: %{tokens: 4}}}
    opts = [human_release_review?: true]

    assert Squad.finalize(invocation, message, outcome, opts) ==
             Finalizer.finalize(invocation, message, outcome, opts)
  end

  test "turns a release-gate recommendation into a human review action" do
    invocation = invocation("squad_leader", "release_gate")
    message = %{body: ~s({"kind":"gate","decision":"approve","reasons":[]})}

    assert {:advance, [_completed, {:gate_review_requested, payload, _metadata}]} =
             Squad.finalize(invocation, message, {:completed, %{}}, human_release_review?: true)

    assert payload["decision"] == "approve"
    assert payload["phase"] == "release_gate"
  end

  defp participant(id, name) do
    %{
      id: id,
      name: name,
      perspective: "verification",
      provider: :simulator,
      model: nil
    }
  end

  defp invocation(role_id, phase) do
    %{
      id: "inv-1",
      message_id: "msg-1",
      turn_id: "turn-1",
      room_id: "room-1",
      participant: participant(role_id, role_id),
      stage: 1,
      phase: phase,
      cycle: 0,
      logical_work_id: "work-1",
      dependencies: [],
      attempt: 1,
      label: phase,
      system_prompt: "prompt",
      completion_metadata: nil,
      status: :running
    }
  end
end
