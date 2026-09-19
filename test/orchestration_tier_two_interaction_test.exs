defmodule ReyCode.Orchestration.TierTwoInteractionTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, ModelTier, Projector, WorkPlan}
  alias ReyCode.Provider.{Frame, Response, Runtime, ToolCall}
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.Notice
  alias ReyCode.TUI.OperatorQuestion, as: QuestionModal

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule Catalog do
    use GenServer
    alias ReyCode.Provider.Runtime

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def fail(server), do: GenServer.call(server, :fail)

    @impl true
    def init(test_pid), do: {:ok, %{available?: true, test_pid: test_pid}}

    @impl true
    def handle_call(:fail, _from, state), do: {:reply, :ok, %{state | available?: false}}

    @impl true
    def handle_call({action, _provider, _model}, _from, %{available?: true} = state)
        when action in [:resolve, :resolve_when_ready, :resolve_continuation] do
      runtime = %Runtime{
        module: ReyCode.Orchestration.TierTwoInteractionTest.Provider,
        status: :available,
        config: %{test_pid: state.test_pid}
      }

      {:reply, {:ok, runtime}, state}
    end

    def handle_call({action, _provider, _model}, _from, state)
        when action in [:resolve, :resolve_when_ready],
        do: {:reply, {:error, :error}, state}

    def handle_call({:resolve_continuation, _provider, nil}, _from, state) do
      runtime = %Runtime{
        module: ReyCode.Orchestration.TierTwoInteractionTest.Provider,
        status: :error,
        config: %{test_pid: state.test_pid}
      }

      {:reply, {:ok, runtime}, state}
    end
  end

  defmodule Provider do
    @behaviour ReyCode.Provider
    alias ReyCode.Provider.{Frame, Response, Runtime, ToolCall}

    @impl true
    def stream(%Runtime{config: %{test_pid: test_pid}}, request, emit) do
      send(test_pid, {:provider_round, request.invocation_id, request.round_index})

      respond(directive(request), request.round_index, test_pid, request, emit)
    end

    defp respond("question", 0, _test_pid, _request, _emit), do: initialize_plan()
    defp respond("question", 1, _test_pid, _request, _emit), do: complete_first_item()
    defp respond("question", 2, _test_pid, _request, _emit), do: ask_operator()

    defp respond("question", 3, test_pid, request, emit),
      do: finish_after_answer(test_pid, request, emit)

    defp respond("catalog-failure", 0, _test_pid, _request, _emit),
      do: ask_operator_then_plan()

    defp respond("catalog-failure", 1, test_pid, request, emit),
      do: finish_after_answer(test_pid, request, emit)

    defp respond("grouped", 0, _test_pid, _request, _emit), do: ask_grouped()

    defp respond("grouped", 1, test_pid, request, emit),
      do: finish_after_grouped_answer(test_pid, request, emit)

    defp respond("reject", 0, _test_pid, _request, _emit), do: ask_rejectable()

    defp respond("reject", 1, test_pid, request, emit),
      do: finish_after_rejection(test_pid, request, emit)

    defp respond("budget", 0, _test_pid, _request, _emit), do: budget_consuming_round()

    defp respond("budget", 1, _test_pid, request, emit) do
      :ok = emit.(Frame.text_delta(request.resume_from + 1, "Finished beyond the old cap"))

      {:ok,
       Response.new(text: "Finished beyond the old cap", usage: %{"total_tokens" => 300_000})}
    end

    defp respond(directive, round_index, _test_pid, _request, _emit) do
      unexpected = {directive, round_index}
      {:error, ReyCode.Failure.new(:internal, "unexpected Tier Two round #{inspect(unexpected)}")}
    end

    defp initialize_plan do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("plan-init", "update_plan", %{
             "action" => "init",
             "phases" => [
               %{"name" => "Build", "items" => ["Inspect", "Implement"]},
               %{"name" => "Verify", "items" => ["Test"]}
             ]
           })
         ],
         usage: %{"total_tokens" => 100}
       )}
    end

    defp complete_first_item do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("plan-done", "update_plan", %{
             "action" => "done",
             "item" => "Inspect"
           })
         ],
         usage: %{"total_tokens" => 100}
       )}
    end

    defp ask_operator do
      {:ok,
       Response.new(
         tool_calls: [operator_question_call()],
         usage: %{"total_tokens" => 100}
       )}
    end

    defp ask_operator_then_plan do
      {:ok,
       Response.new(
         tool_calls: [
           operator_question_call(),
           ToolCall.new("plan-after-answer", "update_plan", %{
             "action" => "init",
             "phases" => [%{"name" => "After answer", "items" => ["Continue"]}]
           })
         ],
         usage: %{"total_tokens" => 100}
       )}
    end

    defp operator_question_call do
      ToolCall.new("ask", "ask_operator", %{
        "question" => "Which implementation path?",
        "options" => [
          %{"label" => "Safe", "description" => "Preserve compatibility"},
          %{"label" => "Fast", "description" => "Prefer speed"}
        ],
        "recommended" => 0
      })
    end

    defp ask_grouped do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("ask-grouped", "ask_operator", %{
             "questions" => [
               %{
                 "header" => "Database",
                 "question" => "Which database?",
                 "options" => [%{"label" => "SQLite"}, %{"label" => "Postgres"}]
               },
               %{
                 "header" => "Region",
                 "question" => "Which region?",
                 "options" => [%{"label" => "East"}, %{"label" => "West"}]
               }
             ]
           })
         ],
         usage: %{"total_tokens" => 100}
       )}
    end

    defp ask_rejectable do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("ask-reject", "ask_operator", %{
             "questions" => [
               %{
                 "header" => "Release",
                 "question" => "Release now?",
                 "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
               }
             ]
           })
         ],
         usage: %{"total_tokens" => 100}
       )}
    end

    defp finish_after_answer(test_pid, request, emit) do
      answer =
        request
        |> latest_tool_content()
        |> Jason.decode!()
        |> Map.fetch!("output")
        |> Jason.decode!()

      selected = answer |> Map.fetch!("selected") |> hd()
      send(test_pid, {:selected_option, selected})
      :ok = emit.(Frame.text_delta(request.resume_from + 1, "finished with #{selected}"))
      {:ok, Response.new(text: "finished with #{selected}", usage: %{"total_tokens" => 100})}
    end

    defp finish_after_grouped_answer(test_pid, request, emit) do
      answer = decoded_tool_output(request)
      send(test_pid, {:grouped_answers, answer["answers"]})
      :ok = emit.(Frame.text_delta(request.resume_from + 1, "finished grouped"))
      {:ok, Response.new(text: "finished grouped", usage: %{"total_tokens" => 100})}
    end

    defp finish_after_rejection(test_pid, request, emit) do
      answer = decoded_tool_output(request)
      send(test_pid, {:rejected_question, answer})
      :ok = emit.(Frame.text_delta(request.resume_from + 1, "continued after rejection"))
      {:ok, Response.new(text: "continued after rejection", usage: %{"total_tokens" => 100})}
    end

    defp decoded_tool_output(request) do
      request
      |> latest_tool_content()
      |> Jason.decode!()
      |> Map.fetch!("output")
      |> Jason.decode!()
    end

    defp budget_consuming_round do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("budget-plan", "update_plan", %{
             "action" => "init",
             "phases" => [%{"name" => "Budget", "items" => ["One"]}]
           })
         ],
         usage: %{"total_tokens" => 250_000}
       )}
    end

    defp directive(request) do
      Enum.find_value(request.messages, fn
        %{role: :user, content: content}
        when content in ["question", "catalog-failure", "grouped", "reject", "budget"] ->
          content

        _other ->
          nil
      end)
    end

    defp latest_tool_content(request) do
      request.messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{role: :tool, name: "ask_operator", content: content} -> content
        _other -> nil
      end)
    end
  end

  setup do
    workspace = Path.join(System.tmp_dir!(), "tier_two_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tier_two_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({Catalog, self()})

    config =
      RuntimeConfig.fresh(
        global_concurrency: 2,
        workspace_concurrency: 1,
        workspace_roots: [workspace],
        allow_simulator_provider: true
      )

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: catalog,
       agent_delay_ms: 0,
       config: config},
      restart: :temporary
    )

    {:ok, session_id} = Engine.create_blank_session("Tier Two", workspace, @engine)
    session = Engine.snapshot(@engine).sessions[session_id]
    primary = Enum.find(session.participants, &(&1.kind == :primary))
    :ok = Engine.configure_participants(session_id, [primary.id], :simulator, nil, @engine)
    %{catalog: catalog, session_id: session_id, primary_id: primary.id, store: store}
  end

  test "question pauses one Invocation, Plan remains durable, and answer resumes", %{
    session_id: session_id
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "question", :direct, @engine)

    invocation =
      Wait.projection(@engine, fn projection ->
        projection.turns[turn_id].invocation_order
        |> Enum.map(&projection.invocations[&1])
        |> Enum.find(&(&1.status == :waiting_operator))
      end)

    assert invocation.coordination.pending_question.question == "Which implementation path?"

    assert Enum.map(invocation.coordination.pending_question.options, & &1.label) == [
             "Safe",
             "Fast"
           ]

    assert statuses(invocation.coordination.work_plan) == [
             completed: "Inspect",
             in_progress: "Implement",
             pending: "Test"
           ]

    term = %Breeze.Term{
      assigns: %{
        engine: @engine,
        modal: nil,
        notice: nil,
        operator_question: QuestionModal.initial(),
        projection: Engine.snapshot(@engine),
        selected_session_id: session_id,
        slash: nil,
        drafts: %{session_id => "preserved draft"}
      }
    }

    opened = QuestionModal.open(term)
    assert opened.assigns.drafts[session_id] == "preserved draft"
    assert {:noreply, review} = QuestionModal.handle_input("1", opened)
    assert {:noreply, answered} = QuestionModal.handle_input("Enter", review)
    assert %Notice{severity: :success} = answered.assigns.notice
    assert {:noreply, stale} = QuestionModal.handle_input("Enter", review)
    assert %Notice{severity: :info} = stale.assigns.notice
    Wait.terminal_turn(@engine, turn_id)
    assert_receive {:selected_option, "Safe"}, 5_000

    final = Engine.snapshot(@engine).invocations[invocation.id]
    assert final.coordination.pending_question == nil
    assert final.coordination.work_plan.updated_at != ""
  end

  test "question continuation survives a later catalog discovery failure", %{
    catalog: catalog,
    session_id: session_id
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "catalog-failure", :direct, @engine)
    invocation = waiting_invocation(turn_id)
    request = invocation.coordination.pending_question

    assert :ok = Catalog.fail(catalog)

    assert :ok =
             Engine.answer_question(
               invocation.id,
               request.id,
               hd(request.options).id,
               @engine
             )

    Wait.terminal_turn(@engine, turn_id)
    final = Engine.snapshot(@engine).invocations[invocation.id]

    after_answer =
      Enum.find(Map.values(final.tool_runs), &(&1.tool_call_id == "plan-after-answer"))

    assert after_answer.status == :completed
    assert final.status == :completed
    assert final.error == nil
    assert_receive {:selected_option, "Safe"}, 5_000
  end

  test "usage beyond all former tier caps does not stop another provider round", %{
    session_id: session_id,
    primary_id: primary_id
  } do
    assert :ok = Engine.configure_participant_tier(session_id, primary_id, :smol, @engine)
    {:ok, turn_id} = Engine.post_message(session_id, "budget", :direct, @engine)
    Wait.terminal_turn(@engine, turn_id)

    projection = Engine.snapshot(@engine)
    [invocation_id] = projection.turns[turn_id].invocation_order
    invocation = projection.invocations[invocation_id]

    assert invocation.execution_context.model_tier == :smol
    assert invocation.execution_context.token_budget_tokens == nil
    assert invocation.status == :completed
    assert invocation.error == nil
    assert_receive {:provider_round, ^invocation_id, 0}, 5_000
    assert_receive {:provider_round, ^invocation_id, 1}, 5_000
    assert ModelTier.used_tokens(invocation) == 550_000
  end

  test "grouped answers complete one ToolRun atomically and resume in frozen order", %{
    session_id: session_id,
    store: store
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "grouped", :direct, @engine)
    invocation = waiting_invocation(turn_id)
    request = invocation.coordination.pending_question

    assert Enum.map(request.questions, & &1.id) == ["question-0", "question-1"]
    assert length(invocation.tool_run_order) == 1

    assert :ok =
             Engine.answer_question(
               invocation.id,
               request.id,
               %{
                 "answers" => [
                   %{"question_id" => "question-1", "option_ids" => ["option-1"]},
                   %{"question_id" => "question-0", "option_ids" => ["option-0"]}
                 ]
               },
               @engine
             )

    Wait.terminal_turn(@engine, turn_id)

    assert_receive {:grouped_answers, answers}, 5_000
    assert Enum.map(answers, & &1["question_id"]) == ["question-0", "question-1"]
    assert Enum.map(answers, & &1["labels"]) == [["SQLite"], ["West"]]

    final = Engine.snapshot(@engine).invocations[invocation.id]
    assert final.coordination.pending_question == nil
    assert [run_id] = final.tool_run_order
    assert final.tool_runs[run_id].status == :completed

    events = EventStore.load(store)
    answered_event = Enum.find(events, &(&1.type == :operator_question_answered))

    assert Enum.map(answered_event.data["answers"], & &1["question_id"]) == [
             "question-0",
             "question-1"
           ]

    assert Projector.replay(events) == Engine.snapshot(@engine)

    wrong_run = %{answered_event | data: Map.put(answered_event.data, "tool_run_id", "run-other")}
    tampered = Enum.map(events, &if(&1.id == answered_event.id, do: wrong_run, else: &1))

    assert_raise ArgumentError, ~r/invalid grouped OperatorQuestion answer event/, fn ->
      Projector.replay(tampered)
    end
  end

  test "question rejection completes the ToolRun, resumes, and rejects stale commands", %{
    session_id: session_id,
    store: store
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "reject", :direct, @engine)
    invocation = waiting_invocation(turn_id)
    request = invocation.coordination.pending_question

    term = %Breeze.Term{
      assigns: %{
        engine: @engine,
        modal: nil,
        notice: nil,
        operator_question: QuestionModal.initial(),
        projection: Engine.snapshot(@engine),
        selected_session_id: session_id,
        slash: nil,
        drafts: %{}
      }
    }

    opened = QuestionModal.open(term)

    assert {:error, :stale_question} =
             Engine.reject_question(invocation.id, "stale-request", @engine)

    assert {:noreply, rejected_term} = QuestionModal.handle_input("Escape", opened)
    assert %Notice{severity: :info, message: "Question rejected"} = rejected_term.assigns.notice

    assert {:error, :question_not_found} =
             Engine.reject_question(invocation.id, request.id, @engine)

    Wait.terminal_turn(@engine, turn_id)
    assert_receive {:rejected_question, %{"rejected" => true}}, 5_000

    final = Engine.snapshot(@engine).invocations[invocation.id]
    [run_id] = final.tool_run_order
    assert final.tool_runs[run_id].result["output"] == ~s({"rejected":true})

    events = EventStore.load(store)
    rejected = Enum.find_index(events, &(&1.type == :operator_question_rejected))
    completed = Enum.find_index(events, &(&1.type == :tool_run_completed))
    assert completed == rejected + 1

    assert Enum.find(events, &(&1.type == :operator_question_rejected)).data["request_id"] ==
             request.id

    assert Projector.replay(events) == Engine.snapshot(@engine)

    rejected_event = Enum.find(events, &(&1.type == :operator_question_rejected))

    wrong_run =
      %{rejected_event | data: Map.put(rejected_event.data, "tool_run_id", "run-other")}

    tampered = Enum.map(events, &if(&1.id == rejected_event.id, do: wrong_run, else: &1))

    assert_raise ArgumentError, ~r/invalid OperatorQuestion rejection event/, fn ->
      Projector.replay(tampered)
    end
  end

  defp waiting_invocation(turn_id) do
    Wait.projection(@engine, fn projection ->
      projection.turns[turn_id].invocation_order
      |> Enum.map(&projection.invocations[&1])
      |> Enum.find(&(&1.status == :waiting_operator))
    end)
  end

  defp statuses(plan) do
    Enum.map(WorkPlan.items(plan), &{&1.status, &1.name})
  end
end
