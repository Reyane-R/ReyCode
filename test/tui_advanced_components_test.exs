defmodule ReyCode.TUI.AdvancedComponentsTest do
  use ExUnit.Case, async: false

  alias ReyCode.ArtifactStore
  alias ReyCode.Orchestration.{Engine, InvocationCoordination, OperatorQuestion}
  alias ReyCode.RuntimeConfig.Artifacts, as: ArtifactPolicy
  alias ReyCode.Tool.Result
  alias ReyCode.TUI.{Artifacts, MergeReview}
  alias ReyCode.TUI.OperatorQuestion, as: QuestionModal

  test "rich question navigation toggles selections and edits Other without resolving" do
    question = %OperatorQuestion{
      id: "question-1",
      tool_run_id: "run-1",
      question: "Which paths?",
      options: [
        %{id: "option-0", label: "Safe", description: "Conservative", preview: "safe preview"},
        %{id: "option-1", label: "Fast", description: "Aggressive", preview: ""}
      ],
      recommended_id: "option-0",
      multi?: true,
      allow_other?: true,
      asked_at: "now"
    }

    invocation = %{
      id: "inv-question",
      coordination: %InvocationCoordination{pending_question: question}
    }

    term = %Breeze.Term{
      assigns: %{
        engine: Engine,
        modal: :operator_question,
        notice: nil,
        operator_question: %{
          QuestionModal.initial()
          | invocation_id: invocation.id,
            question_id: question.id
        },
        projection: %{invocations: %{invocation.id => invocation}}
      }
    }

    assert QuestionModal.focus(term) == term
    assert {:noreply, selected} = QuestionModal.handle_input(" ", term)
    assert selected.assigns.operator_question.selected_ids == ["option-0"]

    assert {:noreply, second} = QuestionModal.handle_input("ArrowDown", selected)
    assert second.assigns.operator_question.index == 1
    assert {:noreply, first} = QuestionModal.handle_input("k", second)
    assert first.assigns.operator_question.index == 0

    assert {:noreply, other_row} = QuestionModal.handle_input("ArrowUp", first)
    assert other_row.assigns.operator_question.index == 2
    assert {:noreply, other_step} = QuestionModal.handle_input(" ", other_row)
    assert other_step.assigns.operator_question.step == :other

    assert {:noreply, edited} =
             QuestionModal.handle_event(
               "question_other_changed",
               %{value: "rollback"},
               other_step
             )

    assert edited.assigns.operator_question.other == "rollback"
    assert QuestionModal.handle_event("unknown", %{}, edited) == :unhandled

    assert {:noreply, options} = QuestionModal.handle_input("Escape", edited)
    assert options.assigns.operator_question.step == :options
    assert {:noreply, closed} = QuestionModal.handle_input("Escape", options)
    assert closed.assigns.modal == nil
    assert closed.focused == "prompt"
  end

  test "artifact list and detail controls page retained output and close cleanly" do
    root = Path.join(System.tmp_dir!(), "artifact-modal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    policy = %ArtifactPolicy{
      root: root,
      spool_threshold_bytes: 16,
      preview_bytes: 32,
      max_artifact_bytes: 32_000,
      max_artifact_count: 4
    }

    first =
      ArtifactStore.spool(Result.ok(String.duplicate("first\n", 2_000)), policy, "inv-1", "run-1")

    second =
      ArtifactStore.spool(
        Result.ok(String.duplicate("second\n", 2_000)),
        policy,
        "inv-2",
        "run-2"
      )

    first_id = first.metadata["artifact_id"]

    term = %Breeze.Term{
      assigns: %{
        artifacts: Artifacts.initial(),
        config: %{artifacts: policy},
        drafts: %{"session" => ""},
        modal: nil,
        notice: nil,
        selected_session_id: "session",
        slash: nil
      }
    }

    opened = Artifacts.open(term)
    assert opened.assigns.modal == :artifacts

    assert {:noreply, moved} = Artifacts.handle_input("j", opened)
    assert moved.assigns.artifacts.index == 1
    assert {:noreply, wrapped} = Artifacts.handle_input("ArrowDown", moved)
    assert wrapped.assigns.artifacts.index == 0

    assert {:noreply, detail} = Artifacts.submit(wrapped)
    assert detail.assigns.artifacts.step == :detail
    assert detail.assigns.artifacts.artifact_id in [first_id, second.metadata["artifact_id"]]
    assert detail.assigns.artifacts.bytes != ""

    assert {:noreply, paged} = Artifacts.handle_input("j", detail)
    assert paged.assigns.artifacts.offset > 0
    assert {:noreply, previous} = Artifacts.handle_input("k", paged)
    assert previous.assigns.artifacts.offset == 0
    assert {:noreply, listed} = Artifacts.handle_input("Escape", previous)
    assert listed.assigns.artifacts.step == :list
    assert {:noreply, closed} = Artifacts.handle_input("Escape", listed)
    assert closed.assigns.modal == nil
    assert Artifacts.handle_event("unknown", %{}, closed) == :unhandled

    empty_policy = %{policy | root: root <> "-empty"}
    empty = put_in(term.assigns.config.artifacts, empty_policy)
    assert Artifacts.open(empty).assigns.notice == "No spooled artifacts"
  end

  test "merge review navigation is bounded and unresolved engine decisions stay visible" do
    diff = Enum.map_join(1..40, "\n", &"+line #{&1}")

    child = %{
      id: "missing-child",
      participant: %{name: "Luna"},
      pending_tool_review: %{tool: "merge", arguments: %{"diff" => diff}}
    }

    term = %Breeze.Term{
      assigns: %{
        agent_hub: %{index: 0},
        engine: Engine,
        merge_review: %{child_invocation_id: child.id, offset: 0},
        modal: :merge_review,
        notice: nil,
        projection: %{invocations: %{child.id => child}}
      }
    }

    assert MergeReview.focus(term) == term
    assert {:noreply, down} = MergeReview.handle_input("j", term)
    assert down.assigns.merge_review.offset == 1
    assert {:noreply, up} = MergeReview.handle_input("ArrowUp", down)
    assert up.assigns.merge_review.offset == 0
    assert {:noreply, unchanged} = MergeReview.handle_input("unknown", up)
    assert unchanged == up
    assert MergeReview.handle_event("unknown", %{}, up) == :unhandled

    assert {:noreply, rejected} = MergeReview.handle_input("A", up)
    assert rejected.assigns.notice =~ "Could not apply"
    assert {:noreply, closed} = MergeReview.handle_input("Escape", rejected)
    assert closed.assigns.modal == :agent_hub
    assert closed.focused == "prompt"
  end
end
