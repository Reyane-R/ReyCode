defmodule ReyCode.TUI.AdvancedComponentsTest do
  use ExUnit.Case, async: false

  alias ReyCode.ArtifactStore
  alias ReyCode.Orchestration.{Engine, InvocationCoordination, OperatorQuestion}
  alias ReyCode.Orchestration.OperatorQuestion.Item
  alias ReyCode.RuntimeConfig.Artifacts, as: ArtifactPolicy
  alias ReyCode.Tool.Result
  alias ReyCode.TUI.{Artifacts, MergeReview, Notice}
  alias ReyCode.TUI.OperatorQuestion, as: QuestionPanel

  test "compact grouped question navigation keeps answers through tabs and request switches" do
    question = grouped_question("request-1", "run-1")

    second_question = %{
      question
      | id: "request-2",
        tool_run_id: "run-2",
        questions: [hd(question.questions)]
    }

    invocation = %{
      id: "inv-question-1",
      participant: %{name: "Builder"},
      coordination: %InvocationCoordination{pending_question: question}
    }

    second_invocation = %{
      id: "inv-question-2",
      participant: %{name: "Reviewer"},
      coordination: %InvocationCoordination{pending_question: second_question}
    }

    term = %Breeze.Term{
      assigns: %{
        engine: Engine,
        modal: nil,
        notice: nil,
        operator_question: QuestionPanel.initial(),
        selected_session_id: "session",
        slash: nil,
        drafts: %{"session" => "preserved draft"},
        projection: %{
          sessions: %{"session" => %{message_order: ["message-1", "message-2"]}},
          messages: %{
            "message-1" => %{invocation_id: invocation.id},
            "message-2" => %{invocation_id: second_invocation.id}
          },
          invocations: %{
            invocation.id => invocation,
            second_invocation.id => second_invocation
          }
        }
      }
    }

    opened = QuestionPanel.open(term)
    assert opened.assigns.modal == :operator_question
    assert opened.assigns.operator_question.request_id == question.id
    assert opened.assigns.drafts["session"] == "preserved draft"

    assert {:noreply, second_tab} = QuestionPanel.handle_input("1", opened)
    assert second_tab.assigns.operator_question.tab_index == 1

    assert {:noreply, selected} = QuestionPanel.handle_input(" ", second_tab)

    assert selected.assigns.operator_question.answers["question-1"].option_ids == [
             "option-0"
           ]

    assert {:noreply, third_tab} = QuestionPanel.handle_input("Enter", selected)
    assert third_tab.assigns.operator_question.tab_index == 2

    assert {:noreply, mouse_other} =
             QuestionPanel.handle_event("question_option_2", %{}, third_tab)

    assert mouse_other.assigns.operator_question.step == :other
    assert mouse_other.focused == "question-other"

    assert {:noreply, other_row} = QuestionPanel.handle_input("ArrowUp", third_tab)
    assert other_row.assigns.operator_question.option_index == 2
    assert {:noreply, other_step} = QuestionPanel.handle_input("Enter", other_row)
    assert other_step.assigns.operator_question.step == :other
    assert other_step.focused == "question-other"

    assert {:noreply, edited} =
             QuestionPanel.handle_event(
               "question_other_changed",
               %{value: "rollback"},
               other_step
             )

    assert edited.assigns.operator_question.answers["question-2"].other == "rollback"
    assert QuestionPanel.handle_event("unknown", %{}, edited) == :unhandled
    assert {:noreply, options} = QuestionPanel.handle_input("Escape", edited)
    assert options.assigns.operator_question.step == :options
    assert options.focused == "prompt"

    assert {:noreply, review} =
             QuestionPanel.handle_event(
               "question_other_submitted",
               %{value: "rollback"},
               other_step
             )

    assert review.assigns.operator_question.tab_index == 3

    assert {:noreply, previous} =
             QuestionPanel.handle_input(%{"key" => "Tab", "shiftKey" => true}, review)

    assert previous.assigns.operator_question.tab_index == 2

    assert {:noreply, switched} = QuestionPanel.handle_input("]", previous)
    assert switched.assigns.operator_question.request_id == second_question.id
    assert {:noreply, answered_second} = QuestionPanel.handle_input("1", switched)

    assert answered_second.assigns.operator_question.answers["question-0"].option_ids == [
             "option-0"
           ]

    assert {:noreply, restored} = QuestionPanel.handle_input("[", answered_second)

    assert restored.assigns.operator_question.answers ==
             previous.assigns.operator_question.answers

    replacement = %{question | id: "request-3", questions: [hd(question.questions)]}

    replaced_projection =
      put_in(
        restored.assigns.projection,
        [:invocations, invocation.id, :coordination, Access.key(:pending_question)],
        replacement
      )

    replaced =
      QuestionPanel.reconcile(%{
        restored
        | assigns: %{restored.assigns | projection: replaced_projection}
      })

    assert replaced.assigns.operator_question.request_id == replacement.id
    assert replaced.assigns.operator_question.answers == %{}
    assert replaced.assigns.operator_question.tab_index == 0
    assert replaced.assigns.notice.message =~ "answers reset"

    first_resolved =
      put_in(
        replaced.assigns.projection,
        [:invocations, invocation.id, :coordination, Access.key(:pending_question)],
        nil
      )

    reconciled =
      QuestionPanel.reconcile(%{
        replaced
        | assigns: %{replaced.assigns | projection: first_resolved}
      })

    assert reconciled.assigns.operator_question.request_id == second_question.id
    assert reconciled.assigns.operator_question.answers["question-0"].option_ids == ["option-0"]
    assert reconciled.assigns.notice.message =~ "resolved elsewhere"

    all_resolved =
      put_in(
        first_resolved,
        [:invocations, second_invocation.id, :coordination, Access.key(:pending_question)],
        nil
      )

    closed =
      QuestionPanel.reconcile(%{
        reconciled
        | assigns: %{reconciled.assigns | projection: all_resolved}
      })

    assert closed.assigns.modal == nil
    assert closed.assigns.operator_question.request_states == %{}
    assert closed.assigns.notice.message =~ "another terminal"
  end

  defp grouped_question(id, tool_run_id) do
    questions = [
      item("question-0", "Database", "Which database?", false, false),
      item("question-1", "Features", "Which features?", true, false),
      item("question-2", "Region", "Which region?", false, true)
    ]

    first = hd(questions)

    %OperatorQuestion{
      id: id,
      tool_run_id: tool_run_id,
      questions: questions,
      question: first.question,
      options: first.options,
      recommended_id: first.recommended_id,
      asked_at: "now"
    }
  end

  defp item(id, header, question, multi?, allow_other?) do
    %Item{
      id: id,
      header: header,
      question: question,
      options: [
        %{id: "option-0", label: "First", description: "Primary", preview: ""},
        %{id: "option-1", label: "Second", description: "Alternate", preview: ""}
      ],
      recommended_id: "option-0",
      multi?: multi?,
      allow_other?: allow_other?
    }
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
    assert %Notice{severity: :info} = Artifacts.open(empty).assigns.notice
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
    assert %Notice{severity: :error} = rejected.assigns.notice
    assert {:noreply, closed} = MergeReview.handle_input("Escape", rejected)
    assert closed.assigns.modal == :agent_hub
    assert closed.focused == "prompt"
  end
end
