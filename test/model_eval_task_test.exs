defmodule ReyCode.ModelEvalTaskTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ReyCode.Eval
  alias ReyCode.{EventStore, ModelEval, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.{Frame, Response, Runtime}

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
      runtime = %Runtime{module: ScriptedProvider, status: :available, executable: test_pid}
      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule ScriptedProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.{Frame, Response}

    @impl true
    def stream(%Runtime{executable: test_pid}, request, emit) do
      task =
        Enum.find_value(request.messages, fn
          %{role: :user, content: content} -> content
          _other -> nil
        end)

      name = request.participant.name
      send(test_pid, {:task_seen, name, task})
      body = "#{name} completed: #{task}"
      :ok = emit.(Frame.text_delta(request.resume_from + 1, body))

      {:ok,
       Response.new(
         text: body,
         usage: usage(name)
       )}
    end

    defp usage("Review"), do: %{"tokens" => %{"input" => 6, "output" => 7}}

    defp usage(name) do
      %{"prompt_tokens" => String.length(name), "completion_tokens" => 7}
    end
  end

  test "runs the same task for exactly the named profiles and reports projection usage" do
    stack = start_stack()
    _source_room = configured_source_room(stack.workspace, ["Luna", "Review"])
    task = "Run the exact focused test"

    report =
      ModelEval.run(
        %{
          agents: ["Luna", "Review"],
          task: task,
          workspace: stack.workspace,
          timeout_ms: 5_000,
          json?: false
        },
        @engine
      )

    assert report.outcome == "completed"
    assert [luna_row, review_row] = report.agents
    assert [luna_row.name, review_row.name] == ["Luna", "Review"]
    assert Enum.all?(report.agents, &(&1.outcome == "completed"))
    assert [luna_row.prompt_tokens, review_row.prompt_tokens] == [4, 6]
    assert [luna_row.completion_tokens, review_row.completion_tokens] == [7, 7]
    assert Enum.all?(report.agents, &(&1.wall_time_ms >= 0))
    assert luna_row.summary =~ "Luna completed"
    assert review_row.summary =~ "Review completed"
    assert ModelEval.success?(report)

    assert_receive {:task_seen, "Luna", ^task}
    assert_receive {:task_seen, "Review", ^task}

    snapshot = Engine.snapshot(@engine)
    turn = Map.fetch!(snapshot.turns, report.turn_id)
    assert length(turn.invocation_order) == 2

    candidates =
      Enum.map(turn.invocation_order, fn id -> Map.fetch!(snapshot.invocations, id) end)

    assert [luna_invocation, review_invocation] = candidates
    assert Enum.all?(candidates, &(&1.participant.kind == :task))
    refute Enum.any?(candidates, &(&1.participant.kind == :primary))
    assert Map.get(luna_invocation.usage, "prompt_tokens") == luna_row.prompt_tokens
    review_tokens = Map.fetch!(review_invocation.usage, "tokens")
    assert Map.get(review_tokens, "input") == review_row.prompt_tokens
  end

  test "an unconfigured name produces an error row while healthy candidates still run" do
    stack = start_stack()
    configured_source_room(stack.workspace, ["Luna"])

    report =
      ModelEval.run(
        %{
          agents: ["Luna", "Missing"],
          task: "Inspect the change",
          workspace: stack.workspace,
          timeout_ms: 5_000,
          json?: true
        },
        @engine
      )

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

  defp configured_source_room(workspace, names) do
    assert {:ok, room_id} = Engine.create_room("Source profiles", workspace, @engine)

    Enum.each(names, fn name ->
      assert {:ok, participant_id} =
               Engine.add_task_participant(room_id, name, "#{name} perspective", @engine)

      assert :ok =
               Engine.configure_participants(room_id, [participant_id], :simulator, nil, @engine)
    end)

    room_id
  end

  defp start_stack do
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
      RuntimeConfig.fresh(
        allow_simulator_provider: true,
        global_concurrency: 4,
        workspace_concurrency: 4,
        workspace_roots: [workspace]
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
       config: config}
    )

    %{workspace: workspace}
  end
end
