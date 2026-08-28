defmodule ReyCode.Orchestration.TierTwoPolicyTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{ModelTier, OperatorQuestions, WorkPlan}

  test "OperatorQuestion freezes two to five bounded options and recommendation" do
    assert {:ok, question} =
             OperatorQuestions.build(
               %{
                 "question" => "Which release path?",
                 "options" => [
                   %{
                     "label" => "Safe",
                     "description" => "Run every gate",
                     "preview" => "@@ -1 +1 @@"
                   },
                   %{"label" => "Fast"}
                 ],
                 "recommended" => 0,
                 "multi" => true,
                 "allow_other" => true
               },
               "question-1",
               "run-1",
               "now"
             )

    assert Enum.map(question.options, & &1.id) == ["option-0", "option-1"]
    assert question.recommended_id == "option-0"
    assert question.multi?
    assert question.allow_other?
    assert hd(question.options).preview == "@@ -1 +1 @@"

    assert {:ok, answer} =
             OperatorQuestions.resolve(question, %{
               option_ids: ["option-0", "option-1"],
               other: "Keep a rollback"
             })

    assert answer.labels == ["Safe", "Fast"]
    assert answer.other == "Keep a rollback"

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.build(
               %{"question" => "Too few", "options" => [%{"label" => "Only"}]},
               "question-2",
               "run-2",
               "now"
             )
  end

  test "WorkPlan auto-promotes, blocks, unblocks, completes, and drops deterministically" do
    assert {:ok, plan} =
             WorkPlan.transition(
               nil,
               %{
                 "action" => "init",
                 "phases" => [
                   %{"name" => "Build", "items" => ["Implement", "Test"]},
                   %{"name" => "Ship", "items" => ["Release"]}
                 ]
               },
               "t1"
             )

    assert statuses(plan) == [in_progress: "Implement", pending: "Test", pending: "Release"]

    assert {:ok, blocked} =
             WorkPlan.transition(
               plan,
               %{"action" => "block", "item" => "Implement", "reason" => "Needs input"},
               "t2"
             )

    assert statuses(blocked) == [blocked: "Implement", in_progress: "Test", pending: "Release"]

    assert {:ok, completed} =
             WorkPlan.transition(blocked, %{"action" => "done", "item" => "Test"}, "t3")

    assert statuses(completed) == [
             blocked: "Implement",
             completed: "Test",
             in_progress: "Release"
           ]

    assert {:ok, unblocked} =
             WorkPlan.transition(completed, %{"action" => "unblock", "item" => "Implement"}, "t4")

    assert {:ok, dropped} =
             WorkPlan.transition(unblocked, %{"action" => "drop", "item" => "Release"}, "t5")

    assert statuses(dropped) == [in_progress: "Implement", completed: "Test", dropped: "Release"]
  end

  test "WorkPlan rejects duplicate and invalid transitions" do
    assert {:error, :plan_too_large} =
             WorkPlan.transition(
               nil,
               %{
                 "action" => "init",
                 "phases" => [
                   %{"name" => "One", "items" => ["Same"]},
                   %{"name" => "Two", "items" => ["Same"]}
                 ]
               },
               "now"
             )

    assert {:error, :invalid_plan_arguments} =
             WorkPlan.transition(nil, %{"action" => "done", "item" => "missing"}, "now")
  end

  test "ModelTier freezes budgets and sums common provider usage shapes" do
    assert ModelTier.all() == [:smol, :default, :slow]
    assert ModelTier.budget_tokens(:smol) == 32_000
    assert ModelTier.budget_tokens(:default) == 100_000
    assert ModelTier.budget_tokens(:slow) == 200_000

    invocation = %{
      token_budget_tokens: 32_000,
      rounds: [
        %{usage: %{"prompt_tokens" => 10_000, "completion_tokens" => 2_000}},
        %{usage: %{"tokens" => %{"input" => 15_000, "output" => 5_000}}}
      ]
    }

    assert ModelTier.used_tokens(invocation) == 32_000
    refute ModelTier.admit_round?(invocation)
  end

  defp statuses(plan) do
    Enum.map(WorkPlan.items(plan), &{&1.status, &1.name})
  end
end
