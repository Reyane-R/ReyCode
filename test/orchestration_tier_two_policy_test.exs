defmodule ReyCode.Orchestration.TierTwoPolicyTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{ModelTier, OperatorQuestion, OperatorQuestions, WorkPlan}

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
    assert {:ok, %{labels: ["Safe"]}} = OperatorQuestions.resolve(question, "option-0")
    assert {:ok, ordered} = OperatorQuestions.resolve(question, ["option-1", "option-0"])
    assert ordered.labels == ["Fast", "Safe"]
    assert {:error, :invalid_question_selection} = OperatorQuestions.resolve(question, 42)

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, %{"option_ids" => [], "other" => 42})

    wire = OperatorQuestion.to_wire(question)

    decoded =
      OperatorQuestion.from_map(%{
        id: wire["question_id"],
        tool_run_id: wire["tool_run_id"],
        questions: wire["questions"],
        question: wire["question"],
        options: wire["options"],
        recommended_id: wire["recommended_id"],
        multi?: wire["multi"],
        allow_other?: wire["allow_other"],
        asked_at: "now"
      })

    assert decoded == question

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.build(
               %{"question" => "Too few", "options" => [%{"label" => "Only"}]},
               "question-2",
               "run-2",
               "now"
             )
  end

  test "OperatorQuestion freezes grouped questions and resolves answers in child order" do
    arguments = %{
      "questions" => [
        %{
          "header" => "Database",
          "question" => "Which database?",
          "options" => [%{"label" => "SQLite"}, %{"label" => "Postgres"}],
          "recommended" => 0
        },
        %{
          "header" => "Deployment",
          "question" => "Which deployment?",
          "options" => [%{"label" => "Local"}, %{"label" => "Cloud"}],
          "allow_other" => true
        }
      ]
    }

    assert {:ok, question} =
             OperatorQuestions.build(arguments, "request-1", "run-1", "now")

    assert Enum.map(question.questions, &{&1.id, &1.header}) == [
             {"question-0", "Database"},
             {"question-1", "Deployment"}
           ]

    assert question.question == "Which database?"
    assert question.options == hd(question.questions).options
    assert question.recommended_id == "option-0"

    assert {:ok, answer} =
             OperatorQuestions.resolve(question, %{
               "answers" => [
                 %{
                   "question_id" => "question-1",
                   "option_ids" => [],
                   "other" => "Fly.io"
                 },
                 %{
                   "question_id" => "question-0",
                   "option_ids" => ["option-1"]
                 }
               ]
             })

    assert Enum.map(answer.answers, & &1.question_id) == ["question-0", "question-1"]
    assert Enum.map(answer.answers, & &1.labels) == [["Postgres"], []]
    assert List.last(answer.answers).other == "Fly.io"
    assert answer.labels == ["Postgres"]

    assert OperatorQuestion.from_map(question) == question
    assert OperatorQuestion.from_map(Map.from_struct(question)) == question
  end

  test "OperatorQuestion grouped arguments and answers fail closed" do
    item = %{
      "header" => "Choice",
      "question" => "Choose",
      "options" => [%{"label" => "One"}, %{"label" => "Two"}]
    }

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.build(
               %{"questions" => [item], "question" => "mixed"},
               "request",
               "run",
               "now"
             )

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.build(
               %{"questions" => [Map.put(item, "unknown", true)]},
               "request",
               "run",
               "now"
             )

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.build(
               %{"questions" => List.duplicate(item, 5)},
               "request",
               "run",
               "now"
             )

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.build(
               %{"questions" => [%{item | "header" => String.duplicate("h", 81)}]},
               "request",
               "run",
               "now"
             )

    assert {:ok, question} =
             OperatorQuestions.build(
               %{"questions" => [item, %{item | "header" => "Second"}]},
               "request",
               "run",
               "now"
             )

    valid = [
      %{"question_id" => "question-0", "option_ids" => ["option-0"]},
      %{"question_id" => "question-1", "option_ids" => ["option-1"]}
    ]

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, %{"answers" => tl(valid)})

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, %{"answers" => [hd(valid), hd(valid)]})

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, %{
               "answers" => [hd(valid), Map.put(List.last(valid), "unknown", true)]
             })

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, "option-0")

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, %{
               "answers" => [
                 %{hd(valid) | "option_ids" => List.duplicate("option-0", 6)},
                 List.last(valid)
               ]
             })

    assert {:error, :invalid_question_selection} =
             OperatorQuestions.resolve(question, %{
               "answers" => [
                 hd(valid),
                 Map.merge(List.last(valid), %{"option_ids" => [], "other" => <<255>>})
               ]
             })
  end

  test "durable OperatorQuestion envelopes restore only within frozen bounds" do
    assert {:ok, question} =
             OperatorQuestions.build(
               %{
                 "questions" => [
                   %{
                     "header" => "Choice",
                     "question" => "Choose",
                     "options" => [%{"label" => "One"}, %{"label" => "Two"}]
                   }
                 ]
               },
               "request",
               "run",
               "now"
             )

    assert {:ok, restored} = OperatorQuestions.restore(Map.from_struct(question))
    assert restored == question

    duplicate = %{hd(question.questions) | id: "question-1"}
    one_option = %{hd(question.questions) | options: [hd(hd(question.questions).options)]}

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.restore(%{
               Map.from_struct(question)
               | questions: [duplicate, duplicate]
             })

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.restore(%{
               Map.from_struct(question)
               | questions: List.duplicate(hd(question.questions), 5)
             })

    assert {:error, :invalid_question_arguments} =
             OperatorQuestions.restore(%{Map.from_struct(question) | questions: [one_option]})
  end

  test "historical singular question maps normalize to singleton groups" do
    historical = %{
      id: "request-legacy",
      tool_run_id: "run-legacy",
      question: "Proceed?",
      options: [
        %{id: "option-0", label: "Yes", description: "", preview: ""},
        %{id: "option-1", label: "No", description: "", preview: ""}
      ],
      recommended_id: nil,
      multi?: false,
      allow_other?: false,
      asked_at: "then"
    }

    question = OperatorQuestion.from_map(historical)
    assert [%{id: "question-0", header: "Question", question: "Proceed?"}] = question.questions
    assert question.legacy_singular?
    assert {:ok, restored} = OperatorQuestions.restore(Map.from_struct(question))
    assert restored.legacy_singular?
    assert OperatorQuestion.to_wire(question)["questions"] |> length() == 1
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

  test "legacy tiers remain readable and provider usage is informational" do
    assert ModelTier.all() == [:smol, :default, :slow]

    invocation = %{
      token_budget_tokens: 32_000,
      rounds: [
        %{usage: %{"prompt_tokens" => 10_000, "completion_tokens" => 2_000}},
        %{usage: %{"tokens" => %{"input" => 15_000, "output" => 5_000}}}
      ]
    }

    assert ModelTier.used_tokens(invocation) == 32_000

    assert ModelTier.used_tokens(%{
             usage: %{
               "prompt_tokens" => 100,
               "input_tokens" => 100,
               "completion_tokens" => 20,
               "output_tokens" => 20
             }
           }) == 120
  end

  defp statuses(plan) do
    Enum.map(WorkPlan.items(plan), &{&1.status, &1.name})
  end
end
