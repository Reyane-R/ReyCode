defmodule ReyCode.Orchestration.TierTwoInteractionTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, WorkPlan}
  alias ReyCode.Provider.{Frame, Response, Runtime, ToolCall}
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.OperatorQuestion, as: QuestionModal

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule Catalog do
    use GenServer
    alias ReyCode.Provider.Runtime

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready] do
      runtime = %Runtime{
        module: ReyCode.Orchestration.TierTwoInteractionTest.Provider,
        status: :available,
        executable: test_pid
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule Provider do
    @behaviour ReyCode.Provider
    alias ReyCode.Provider.{Frame, Response, Runtime, ToolCall}

    @impl true
    def stream(%Runtime{executable: test_pid}, request, emit) do
      send(test_pid, {:provider_round, request.invocation_id, request.round_index})

      case {directive(request), request.round_index} do
        {"question", 0} ->
          initialize_plan()

        {"question", 1} ->
          complete_first_item()

        {"question", 2} ->
          ask_operator()

        {"question", 3} ->
          finish_after_answer(test_pid, request, emit)

        {"budget", 0} ->
          budget_consuming_round()

        other ->
          {:error, ReyCode.Failure.new(:internal, "unexpected Tier Two round #{inspect(other)}")}
      end
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
         tool_calls: [
           ToolCall.new("ask", "ask_operator", %{
             "question" => "Which implementation path?",
             "options" => [
               %{"label" => "Safe", "description" => "Preserve compatibility"},
               %{"label" => "Fast", "description" => "Prefer speed"}
             ],
             "recommended" => 0
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

    defp budget_consuming_round do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("budget-plan", "update_plan", %{
             "action" => "init",
             "phases" => [%{"name" => "Budget", "items" => ["One"]}]
           })
         ],
         usage: %{"total_tokens" => 32_000}
       )}
    end

    defp directive(request) do
      Enum.find_value(request.messages, fn
        %{role: :user, content: content} when content in ["question", "budget"] -> content
        _other -> nil
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
    %{session_id: session_id, primary_id: primary.id}
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

    question = invocation.coordination.pending_question

    term = %Breeze.Term{
      assigns: %{
        engine: @engine,
        modal: :operator_question,
        notice: nil,
        operator_question: %{
          QuestionModal.initial()
          | invocation_id: invocation.id,
            question_id: question.id,
            selected_ids: ["option-0"]
        },
        projection: Engine.snapshot(@engine)
      }
    }

    assert {:noreply, answered} = QuestionModal.handle_input("Enter", term)
    assert answered.assigns.notice == "Answered: Safe"
    assert {:noreply, stale} = QuestionModal.submit(term)
    assert stale.assigns.notice =~ "Could not answer"
    Wait.terminal_turn(@engine, turn_id)
    assert_receive {:selected_option, "Safe"}, 5_000

    final = Engine.snapshot(@engine).invocations[invocation.id]
    assert final.coordination.pending_question == nil
    assert final.coordination.work_plan.updated_at != ""
  end

  test "smol tier freezes a 32k budget and stops before another provider round", %{
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
    assert invocation.execution_context.token_budget_tokens == 32_000
    assert invocation.status == :failed
    assert invocation.error.category == :token_budget_exceeded
    assert_receive {:provider_round, ^invocation_id, 0}, 5_000
    refute_receive {:provider_round, ^invocation_id, 1}, 50
  end

  defp statuses(plan) do
    Enum.map(WorkPlan.items(plan), &{&1.status, &1.name})
  end
end
