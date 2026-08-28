defmodule ReyCode.ModelEvalTaskTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ReyCode.Eval
  alias ReyCode.{EventStore, ModelEval, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.{Response, Runtime}

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule ScriptedCatalog do
    use GenServer

    alias ReyCode.ModelEvalTaskTest.ScriptedProvider
    alias ReyCode.Provider.Runtime

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid))

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready] and
               provider in [:unconfigured, "unconfigured"] do
      {:reply, {:error, :unknown_provider}, test_pid}
    end

    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready] do
      if action == :resolve_when_ready, do: send(test_pid, :resolve_when_ready)
      runtime = %Runtime{module: ScriptedProvider, status: :available, executable: test_pid}
      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule ScriptedProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.{Frame, Response, ToolCall}

    @impl true
    def stream(%Runtime{executable: test_pid}, request, emit) do
      task =
        Enum.find_value(request.messages, fn
          %{role: :user, content: content} -> content
          _other -> nil
        end)

      name = request.participant.name
      send(test_pid, {:task_seen, name, task})

      cond do
        task == "block" ->
          receive do
            :release ->
              {:error, %{category: "internal", message: "unexpected release", retryable: false}}
          after
            5_000 -> {:error, %{category: "internal", message: "test timeout", retryable: false}}
          end

        name == "Review" and request.round_index == 0 ->
          {:ok,
           Response.new(
             tool_calls: [ToolCall.new("read-mix", "read", %{"path" => "mix.exs"})],
             usage: %{"tokens" => %{"input" => 6, "output" => 7}}
           )}

        true ->
          body = "#{name} completed: #{task}"
          :ok = emit.(Frame.text_delta(request.resume_from + 1, body))
          {:ok, Response.new(text: body, usage: usage(name))}
      end
    end

    defp usage("Review"), do: %{"tokens" => %{"input" => 8, "output" => 9}}

    defp usage(name) do
      %{"prompt_tokens" => String.length(name), "completion_tokens" => 7}
    end
  end

  test "runs exactly named profiles, ignores stale copies, waits readiness, and totals rounds" do
    stack = start_stack()
    configured_source_room(stack.workspace, ["Luna", "Review"])

    assert {:ok, stale_room} =
             Engine.create_blank_session("Newer unconfigured copy", stack.workspace, @engine)

    assert {:ok, _stale_id} =
             Engine.add_task_participant(stale_room, "Luna", "stale profile", @engine)

    task = "Run the exact focused test"
    report = ModelEval.run(options(stack, ["Luna", "Review"], task), @engine)

    assert report.outcome == "completed"
    assert [luna_row, review_row] = report.agents
    assert [luna_row.name, review_row.name] == ["Luna", "Review"]
    assert [luna_row.prompt_tokens, review_row.prompt_tokens] == [4, 14]
    assert [luna_row.completion_tokens, review_row.completion_tokens] == [7, 16]
    assert Enum.all?(report.agents, &(&1.wall_time_ms >= 0))
    assert luna_row.summary =~ "Luna completed"
    assert review_row.summary =~ "Review completed"
    assert ModelEval.success?(report)

    assert_receive :resolve_when_ready
    assert_receive :resolve_when_ready
    assert_receive {:task_seen, "Luna", ^task}
    assert_receive {:task_seen, "Review", ^task}

    snapshot = Engine.snapshot(@engine)
    turn = Map.fetch!(snapshot.turns, report.turn_id)
    assert length(turn.invocation_order) == 2

    assert [luna_invocation, review_invocation] =
             Enum.map(turn.invocation_order, &Map.fetch!(snapshot.invocations, &1))

    assert Enum.all?([luna_invocation, review_invocation], &(&1.participant.kind == :task))
    assert Map.get(luna_invocation.usage, "prompt_tokens") == 4

    review_inputs =
      Enum.map(review_invocation.rounds, fn round ->
        round.usage |> Map.fetch!("tokens") |> Map.fetch!("input")
      end)

    assert review_inputs == [6, 8]
    assert Enum.sum(review_inputs) == review_row.prompt_tokens
  end

  test "an unconfigured name produces an error row while healthy candidates still run" do
    stack = start_stack()
    configured_source_room(stack.workspace, ["Luna"])

    report = ModelEval.run(options(stack, ["Luna", "Missing"], "Inspect the change"), @engine)

    assert report.outcome == "failed"
    assert [luna_row, missing_row] = report.agents
    assert luna_row.outcome == "completed"
    assert missing_row.outcome == "unconfigured"
    assert missing_row.summary == "agent_not_found"
    refute ModelEval.success?(report)
    assert_raise Mix.Error, fn -> Eval.ensure_success!(report) end
    assert_receive {:task_seen, "Luna", "Inspect the change"}
    refute_receive {:task_seen, "Missing", _task}
  end

  test "unfinished candidates retain timed_out outcome after cancellation" do
    stack = start_stack()
    configured_source_room(stack.workspace, ["Luna"])

    report = ModelEval.run(options(stack, ["Luna"], "block", 30), @engine)

    assert [%{outcome: "timed_out", wall_time_ms: 30}] = report.agents
    assert report.outcome == "failed"
  end

  test "turn admission errors produce a complete failure report" do
    stack = start_stack(global_concurrency: 1, global_queue_limit: 0)
    source_room = configured_source_room(stack.workspace, ["Luna"])
    snapshot = Engine.snapshot(@engine)

    primary =
      Enum.find(Map.fetch!(snapshot.sessions, source_room).participants, &(&1.kind == :primary))

    assert :ok =
             Engine.configure_participants(source_room, [primary.id], :simulator, nil, @engine)

    assert {:ok, _blocking_turn} = Engine.post_message(source_room, "block", :direct, @engine)
    assert_receive {:task_seen, "Assistant", "block"}

    report = ModelEval.run(options(stack, ["Luna"], "queue pressure"), @engine)

    assert report.turn_id == nil
    assert report.outcome == "failed"
    assert [%{name: "Luna", outcome: "failed", summary: summary}] = report.agents
    assert summary =~ "turn_admission_failed"
    assert summary =~ "global_queue_full"
  end

  test "eval admission rejects a room with no task participants" do
    stack = start_stack()

    assert {:ok, session_id} =
             Engine.create_blank_session("No candidates", stack.workspace, @engine)

    assert {:error, :eval_participants_required} =
             Engine.post_message(session_id, "Never strand this room", :eval, @engine)
  end

  test "renders identical human and JSON fields and enforces both exit branches" do
    report = %{
      turn_id: "turn-1",
      outcome: "completed",
      agents: [
        %{
          name: "Luna",
          outcome: "completed",
          summary: "all green",
          prompt_tokens: 12,
          completion_tokens: 3,
          wall_time_ms: 45
        }
      ]
    }

    human = ModelEval.render(report, :human)
    assert human =~ "Agent\tOutcome\tPrompt\tCompletion\tWall ms\tResponse"
    assert human =~ "Luna\tcompleted\t12\t3\t45\tall green"

    json = report |> ModelEval.render(:json) |> Jason.decode!()
    assert [agent] = Map.fetch!(json, "agents")
    assert Map.get(agent, "name") == "Luna"
    assert Map.get(agent, "wall_time_ms") == 45
    assert :ok = Eval.ensure_success!(report)
  end

  test "parses repeated agents and rejects invalid invocations" do
    opts =
      Eval.parse!([
        "--agent",
        "Luna",
        "--agent",
        "Review",
        "--task",
        "same task",
        "--workspace",
        File.cwd!(),
        "--timeout-ms",
        "1234",
        "--json"
      ])

    assert opts.agents == ["Luna", "Review"]
    assert opts.task == "same task"
    assert opts.timeout_ms == 1_234
    assert opts.json?

    assert_raise Mix.Error, fn -> Eval.parse!(["--task", "missing agents"]) end

    assert_raise Mix.Error, ~r/unique/, fn ->
      Eval.parse!(["--agent", "Luna", "--agent", "Luna", "--task", "duplicate"])
    end

    assert_raise Mix.Error, ~r/timeout/, fn ->
      Eval.parse!(["--agent", "Luna", "--task", "bad timeout", "--timeout-ms", "0"])
    end
  end

  defp options(stack, agents, task, timeout_ms \\ 5_000) do
    %{
      agents: agents,
      task: task,
      workspace: stack.workspace,
      timeout_ms: timeout_ms,
      json?: false,
      provider_catalog: stack.catalog
    }
  end

  defp configured_source_room(workspace, names) do
    assert {:ok, session_id} = Engine.create_blank_session("Source profiles", workspace, @engine)

    Enum.each(names, fn name ->
      assert {:ok, participant_id} =
               Engine.add_task_participant(session_id, name, "#{name} perspective", @engine)

      assert :ok =
               Engine.configure_participants(
                 session_id,
                 [participant_id],
                 :simulator,
                 nil,
                 @engine
               )
    end)

    session_id
  end

  defp start_stack(overrides \\ []) do
    workspace = Path.join(System.tmp_dir!(), "model_eval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_model_eval_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({ScriptedCatalog, test_pid: self()})

    config =
      [
        allow_simulator_provider: true,
        global_concurrency: 4,
        workspace_concurrency: 4,
        workspace_roots: [workspace]
      ]
      |> Keyword.merge(overrides)
      |> RuntimeConfig.fresh()

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: catalog,
       agent_delay_ms: 0,
       config: config}
    )

    %{workspace: workspace, catalog: catalog}
  end
end
