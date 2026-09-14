defmodule ReyCode.VerifiedChangeInteractiveTest do
  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{DelegationWorktree, Engine, Projector}

  @engine __MODULE__.Engine
  @registry __MODULE__.Registry
  @events __MODULE__.Events
  @supervisor __MODULE__.Supervisor
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} = context do
    source = Path.join(dir, "source")
    File.mkdir!(source)
    git!(source, ["init", "-q"])
    File.write!(Path.join(source, "value.txt"), "before\n")
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "fixture"
    ])

    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({Registry, keys: :duplicate, name: @events})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @supervisor})
    store = start_supervised!({EventStore, name: nil, path: Path.join(dir, "events.sqlite3")})

    config =
      RuntimeConfig.fresh(
        tool_permissions: %{
          default: :allow,
          rules: [%{tool: "write", action: :ask}, %{tool: "bash", action: :ask}]
        },
        default_provider: :simulator,
        allow_simulator_provider: true,
        provider_discovery: false,
        agent_delay_ms: Map.get(context, :delay_ms, 0)
      )

    opts = [
      name: @engine,
      event_store: store,
      agent_registry: @registry,
      event_registry: @events,
      agent_supervisor: @supervisor,
      config: config,
      simulator_opts: [
        seed: 0,
        delay_ms: 0,
        jitter_ms: 0,
        failure_rate: 0.0,
        tool_requests: Map.get(context, :tools, [])
      ]
    ]

    start_supervised!({Engine, opts})
    {:ok, source_id} = Engine.create_blank_session("Source", source, @engine)
    Engine.subscribe(@engine)

    on_exit(fn ->
      if Process.whereis(@engine) do
        for {_id, session} <- Engine.snapshot(@engine).sessions,
            record = session.verified_change,
            not is_nil(record) do
          Engine.cancel_verified_change(session.id, @engine)

          DelegationWorktree.cleanup(%{
            source_workspace: record.source_workspace,
            workspace: record.workspace
          })
        end
      end
    end)

    %{source: source, source_id: source_id, store: store, opts: opts}
  end

  test "interactive admission freezes the workflow and creates report-only stage participants",
       context do
    session_id =
      start_change(context,
        testing_provider: "simulator",
        testing_model: "analysis-model",
        release_provider: "simulator",
        release_model: "release-model"
      )

    record = await_phase(session_id, "ready")

    assert record.workflow == %{
             "testing" => %{"provider" => "simulator", "model" => "analysis-model"},
             "release" => %{"provider" => "simulator", "model" => "release-model"}
           }

    session = Engine.snapshot(@engine).sessions[session_id]
    testing = Enum.find(session.participants, &(&1.name == "Testing"))
    release = Enum.find(session.participants, &(&1.name == "Release"))
    assert testing.kind == :task and release.kind == :task
    assert to_string(testing.provider) == "simulator"
    assert testing.model_tier == :smol and release.model_tier == :smol
    assert record.analysis == nil
    assert %{"outcome" => "completed", "error" => nil} = record.metadata
    assert is_binary(record.metadata["response"]) and record.metadata["response"] != ""
    assert Projector.replay(EventStore.load(context.store)) == Engine.snapshot(@engine)
  end

  @tag tools: [%{tool: "write", arguments: %{"path" => "value.txt", "content" => "after\n"}}]
  test "approval waits without cancellation, then retains ready evidence without applying source",
       context do
    session_id = start_change(context)
    invocation = await_invocation(session_id, :waiting_tool_approval)
    run = invocation.tool_runs |> Map.values() |> Enum.find(&(&1.status == :awaiting_approval))
    assert run
    assert journal(session_id).phase == "implementing"
    assert Engine.verified_change_status(session_id, @engine) == :running
    assert File.read!(Path.join(journal(session_id).workspace, "value.txt")) == "before\n"
    assert :ok = Engine.resolve_tool_run(invocation.id, run.id, :approve, @engine)
    record = await_phase(session_id, "ready")
    assert record.patch =~ "+after"
    assert [%{"exit_code" => 0}] = record.checks
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
    assert Projector.replay(EventStore.load(context.store)) == Engine.snapshot(@engine)
  end

  @tag tools: [
         %{
           tool: "ask_operator",
           arguments: %{
             "question" => "Which choice?",
             "options" => [%{"label" => "A"}, %{"label" => "B"}]
           }
         }
       ]
  test "operator question waits while navigation and ordinary steering remain independent",
       context do
    session_id = start_change(context)
    invocation = await_invocation(session_id, :waiting_operator)
    {:ok, other_id} = Engine.create_session(context.source_id, "Navigate elsewhere", @engine)
    assert other_id != session_id
    assert :ok = Engine.steer_turn(invocation.turn_id, "Keep the original goal", @engine)

    assert {:error, :verified_change_not_owner} =
             Engine.post_message(session_id, "Escape", :direct, @engine)

    assert {:error, :verified_change_not_owner} =
             Engine.run_owner_command(session_id, "true", @engine)

    question = invocation.coordination.pending_question
    option = hd(question.options)
    assert :ok = Engine.answer_question(invocation.id, question.id, option.id, @engine)
    assert await_phase(session_id, "ready").error == nil
  end

  test "durable receipt and responsive snapshot precede completion of a blocked check", context do
    gate = Path.join(context.tmp_dir, "gate")
    command = "while ! test -f '#{gate}'; do sleep 0.01; done"
    session_id = start_change(context, commands: [command])
    snapshot = Engine.snapshot(@engine)
    session = snapshot.sessions[session_id]
    assert session.verified_change.id
    assert session.workspace == session.verified_change.workspace
    assert session.workspace != context.source
    assert File.dir?(session.workspace)

    assert {:error, :verified_change_already_active} =
             Engine.start_verified_change(context.source_id, options(), @engine)

    assert await_phase(session_id, "baseline")
    assert :ok = Engine.cancel_verified_change(session_id, @engine)
    assert journal(session_id).phase == "blocked"
    File.write!(gate, "release")
    await(fn -> Engine.verified_change_status(session_id, @engine) == :stopped end)
    assert journal(session_id).phase == "blocked"
    assert Engine.snapshot(@engine).sessions[session_id].active_turn_id == nil
  end

  test "copies the explicitly initiating runtime, not a newer Session", context do
    source = Engine.snapshot(@engine).sessions[context.source_id]
    primary = Enum.find(source.participants, &(&1.kind == :primary))
    assert :ok = Engine.configure_participant_tier(source.id, primary.id, :slow, @engine)
    {:ok, newer_id} = Engine.create_blank_session("Newer", context.source, @engine)
    newer = Engine.snapshot(@engine).sessions[newer_id]
    newer_primary = Enum.find(newer.participants, &(&1.kind == :primary))
    assert :ok = Engine.configure_participant_tier(newer_id, newer_primary.id, :smol, @engine)
    session_id = start_change(context)
    assert [copied] = Engine.snapshot(@engine).sessions[session_id].participants
    assert copied.model_tier == :slow
    assert copied.provider == primary.provider
    assert copied.model == primary.model
    await_phase(session_id, "ready")
  end

  @tag tools: [%{tool: "write", arguments: %{"path" => "value.txt", "content" => "after\n"}}]
  test "denied approval blocks rather than declaring ready", context do
    session_id = start_change(context)
    invocation = await_invocation(session_id, :waiting_tool_approval)
    run = invocation.tool_runs |> Map.values() |> Enum.find(&(&1.status == :awaiting_approval))
    assert :ok = Engine.resolve_tool_run(invocation.id, run.id, :deny, @engine)
    assert await_phase(session_id, "blocked").error
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
  end

  test "global admission is bounded while accepted callers may exit", context do
    options = options(commands: ["sleep 10"])
    task = Task.async(fn -> Engine.start_verified_change(context.source_id, options, @engine) end)
    assert {:ok, first} = Task.await(task)
    {:ok, second_source} = Engine.create_blank_session("Second", context.source, @engine)
    {:ok, third_source} = Engine.create_blank_session("Third", context.source, @engine)
    assert {:ok, second} = Engine.start_verified_change(second_source, options, @engine)

    assert {:error, :verified_change_capacity} =
             Engine.start_verified_change(third_source, options, @engine)

    assert Engine.verified_change_status(first, @engine) == :running
    for id <- [first, second], do: assert(:ok = Engine.cancel_verified_change(id, @engine))

    await(fn ->
      Enum.all?([first, second], &(Engine.verified_change_status(&1, @engine) == :stopped))
    end)
  end

  test "Engine exit stops the coordinator and recovery blocks without restarting checks",
       context do
    marker = Path.join(context.tmp_dir, "check-started")
    gate = Path.join(context.tmp_dir, "check-release")
    command = "printf started >> '#{marker}'; while ! test -f '#{gate}'; do sleep 0.01; done"
    session_id = start_change(context, commands: [command])
    await(fn -> File.exists?(marker) end)
    workers = DynamicSupervisor.which_children(@supervisor)
    refs = Enum.map(workers, fn {_id, pid, _type, _modules} -> Process.monitor(pid) end)
    stop_supervised!(Engine)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason}, 10_000)
    start_supervised!({Engine, context.opts})
    assert journal(session_id).phase == "blocked"
    assert journal(session_id).error =~ "not resumed"
    assert DynamicSupervisor.which_children(@supervisor) == []
    assert Engine.verified_change_status(session_id, @engine) == :stopping

    assert {:error, :verified_change_stopping} =
             Engine.start_verified_change(context.source_id, options(), @engine)

    File.write!(gate, "release")
    await(fn -> Engine.verified_change_status(session_id, @engine) == :stopped end)
    assert File.read!(marker) == "started"
  end

  @tag tools: [
         %{
           tool: "ask_operator",
           arguments: %{
             "question" => "Wait?",
             "options" => [%{"label" => "A"}, %{"label" => "B"}]
           }
         }
       ]
  test "the total deadline includes operator waits", context do
    session_id = start_change(context, timeout_ms: 3_000)
    await_invocation(session_id, :waiting_operator)
    record = await_phase(session_id, "blocked")
    assert record.error =~ "deadline" or record.error =~ "timeout" or record.error =~ "timed out"
    await(fn -> Engine.verified_change_status(session_id, @engine) == :stopped end)
    assert Engine.snapshot(@engine).sessions[session_id].active_turn_id == nil
  end

  @tag tools: [%{tool: "bash", arguments: %{"command" => "true"}}]
  test "interactive Turn policy waits on real Engine approval broadcasts", context do
    task =
      Task.async(fn ->
        ReyCode.OneShot.run_turn(
          context.source_id,
          "Run the check",
          10_000,
          @engine,
          :interactive
        )
      end)

    invocation = await_invocation(context.source_id, :waiting_tool_approval)
    run = invocation.tool_runs |> Map.values() |> Enum.find(&(&1.status == :awaiting_approval))
    assert Engine.snapshot(@engine).turns[invocation.turn_id].status == :running
    assert :ok = Engine.resolve_tool_run(invocation.id, run.id, :approve, @engine)
    assert {:ok, %{outcome: :completed}} = Task.await(task, 10_000)
  end

  @tag tools: [
         %{
           tool: "ask_operator",
           arguments: %{
             "question" => "Which?",
             "options" => [%{"label" => "A"}, %{"label" => "B"}]
           }
         }
       ]
  test "interactive Turn policy waits on real Engine operator answers", context do
    task =
      Task.async(fn ->
        ReyCode.OneShot.run_turn(
          context.source_id,
          "Ask the operator",
          10_000,
          @engine,
          :interactive
        )
      end)

    invocation = await_invocation(context.source_id, :waiting_operator)
    question = invocation.coordination.pending_question

    assert :ok =
             Engine.answer_question(invocation.id, question.id, hd(question.options).id, @engine)

    assert {:ok, %{outcome: :completed}} = Task.await(task, 10_000)
  end

  test "invalid requests never create a durable Session", context do
    before = Engine.snapshot(@engine)

    assert {:error, :session_not_found} =
             Engine.start_verified_change("missing", options(), @engine)

    assert {:error, :invalid_verified_change_options} =
             Engine.start_verified_change(context.source_id, nil, @engine)

    assert {:error, _} =
             Engine.start_verified_change(context.source_id, options(commands: []), @engine)

    assert Engine.snapshot(@engine) == before
  end

  defp start_change(context, overrides \\ []) do
    assert {:ok, session_id} =
             Engine.start_verified_change(context.source_id, options(overrides), @engine)

    workspace = journal(session_id).workspace

    on_exit(fn ->
      DelegationWorktree.cleanup(%{source_workspace: context.source, workspace: workspace})
    end)

    session_id
  end

  defp options(overrides \\ []) do
    Map.merge(
      %{
        prompt: "Change before to after",
        commands: ["cat value.txt"],
        timeout_ms: 30_000,
        max_repair_count: 0,
        check_timeout_ms: 15_000
      },
      Map.new(overrides)
    )
  end

  defp journal(session_id), do: Engine.snapshot(@engine).sessions[session_id].verified_change

  defp await_phase(session_id, phase) do
    await(fn ->
      record = journal(session_id)
      if record.phase == phase, do: record
    end)
  end

  defp await_invocation(session_id, status) do
    await(fn ->
      Engine.snapshot(@engine).invocations
      |> Map.values()
      |> Enum.find(&(&1.session_id == session_id and &1.status == status))
    end)
  end

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + 15_000)

  defp await(predicate, deadline_ms) do
    case predicate.() do
      value when value not in [nil, false] ->
        value

      _ ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)
        assert remaining_ms > 0, "interactive verification did not reach the expected state"

        receive do
          {:projection_snapshot, _projection} -> await(predicate, deadline_ms)
        after
          min(remaining_ms, 20) -> await(predicate, deadline_ms)
        end
    end
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end
end
