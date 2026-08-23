defmodule ReyCode.Orchestration.SquadEngineTest do
  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, Projector, Squad}
  alias ReyCode.Test.Wait

  test "leader supervises the fixed workflow through architecture and release" do
    %{engine: engine, store: store} =
      start_isolated_engine(simulator_opts: [delay_ms: 0, seed: 123])

    room_id = configure_squad(engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Deliver the squad workflow", :squad, engine)

    turn = wait_until_terminal(turn_id, engine)
    snapshot = Engine.snapshot(engine)
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.status == :completed
    assert turn.squad.workflow_version == "squad-v3"
    assert turn.squad.phase == "release_gate"
    assert turn.squad.rework_count == 0
    assert length(invocations) == 16
    assert Enum.map(invocations, & &1.participant.id) == ~w(
             squad_leader analyst reviewer squad_leader gherkin_author qa_author squad_leader
             implementer senior_implementer cleaner code_reviewer squad_leader hardener qa_tester
             architect squad_leader
           )

    assert Enum.all?(turn.squad.decisions, &(&1.role_id == "squad_leader"))

    assert MapSet.new(turn.squad.artifacts, & &1.kind) ==
             MapSet.new(~w(
               theme_brief stories story_review gherkin qa_plan code unit_tests acceptance_tests
               integrated_implementation cleaned_code code_review hardened_code qa_evidence
               architecture_review
             ))

    replayed = EventStore.load(store) |> Projector.replay()
    assert replayed.turns[turn_id] == snapshot.turns[turn_id]
  end

  test "leader rework returns to senior integration and completes" do
    %{engine: engine, store: store} =
      start_isolated_engine(simulator_opts: [delay_ms: 0, seed: 456, leader_rework_rounds: 1])

    room_id = configure_squad(engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Exercise bounded rework", :squad, engine)

    turn = wait_until_terminal(turn_id, engine)

    assert turn.status == :completed
    assert turn.squad.rework_count == 1
    assert turn.squad.cycle == 1
    assert Enum.count(turn.squad.artifacts, &(&1.kind == "integrated_implementation")) == 2

    assert Enum.any?(EventStore.load(store), fn event ->
             event.type == :squad_retry_scheduled and event.data["kind"] == "rework" and
               event.data["turn_id"] == turn_id
           end)
  end

  test "transient worker failures create a durable second attempt without duplicate work" do
    %{engine: engine} =
      start_isolated_engine(
        simulator_opts: [
          delay_ms: 0,
          seed: 789,
          failure_plan: %{{"stories", "analyst", 1} => :retryable}
        ]
      )

    room_id = configure_squad(engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Exercise retry", :squad, engine)

    turn = wait_until_terminal(turn_id, engine)
    snapshot = Engine.snapshot(engine)

    analyst_attempts =
      turn.invocation_order
      |> Enum.map(&snapshot.invocations[&1])
      |> Enum.filter(&(&1.phase == "stories"))

    assert turn.status == :completed
    assert Enum.map(analyst_attempts, & &1.attempt) == [1, 2]
    assert Enum.uniq_by(analyst_attempts, & &1.logical_work_id) |> length() == 1
  end

  test "permanent worker failure terminates after one attempt without hanging" do
    %{engine: engine, store: store} =
      start_isolated_engine(
        simulator_opts: [
          delay_ms: 0,
          seed: 790,
          failure_plan: %{{"stories", "analyst", 1} => :permanent}
        ]
      )

    room_id = configure_squad(engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Do not retry permanent errors", :squad, engine)

    turn = wait_until_terminal(turn_id, engine)
    snapshot = Engine.snapshot(engine)

    analyst_attempts =
      turn.invocation_order
      |> Enum.map(&snapshot.invocations[&1])
      |> Enum.filter(&(&1.phase == "stories"))

    assert turn.status == :failed
    assert Enum.map(analyst_attempts, & &1.attempt) == [1]
    assert hd(analyst_attempts).error["retryable"] == false

    refute Enum.any?(EventStore.load(store), fn event ->
             event.type == :squad_retry_scheduled and event.data["turn_id"] == turn_id and
               event.data["kind"] == "provider_retry"
           end)
  end

  test "configures fixed squad role runtimes durably" do
    room_id = ReyCode.snapshot().room_order |> hd()

    assert :ok = Engine.configure_squad_roles(room_id, ["analyst", "architect"], :simulator, nil)
    room = ReyCode.snapshot().rooms[room_id]

    assert room.squad_roles["analyst"].provider == :simulator
    assert room.squad_roles["architect"].name == "Architect"
  end

  test "records an owner directive on a running squad turn" do
    %{engine: engine, store: store} =
      start_isolated_engine(simulator_opts: [delay_ms: 1_000, seed: 321])

    room_id = configure_squad(engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Steer this squad", :squad, engine)

    on_exit(fn ->
      if GenServer.whereis(engine), do: Engine.cancel_turn(turn_id, "test cleanup", engine)
    end)

    assert :ok = Engine.add_squad_directive(turn_id, "Keep the first release read-only.", engine)

    assert [directive] = Engine.snapshot(engine).turns[turn_id].squad.directives
    assert directive.text == "Keep the first release read-only."
    assert directive.phase == "leader_intake"

    assert Enum.any?(EventStore.load(store), fn event ->
             event.type == :squad_directive_added and event.data["turn_id"] == turn_id
           end)

    assert {:error, :empty_directive} = Engine.add_squad_directive(turn_id, "   ", engine)
    assert :ok = Engine.cancel_turn(turn_id, "test", engine)

    assert {:error, :squad_not_running} =
             Engine.add_squad_directive(turn_id, "Too late", engine)
  end

  test "holds the release gate for the owner and advances after approval" do
    %{engine: engine, store: store} = start_isolated_engine(squad_release_gate_human: true)
    room_id = first_room_id(engine)
    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Require owner release approval", :squad, engine)

    turn = wait_until_pending_review(turn_id, engine)
    assert turn.status == :running
    assert turn.squad.phase == "release_gate"
    assert turn.squad.pending_review.decision == "approve"
    assert turn.squad.pending_review.actor == "agent"
    refute Enum.any?(turn.squad.decisions, &(&1.phase == "release_gate"))

    review_id = turn.squad.pending_review.review_id

    assert {:error, :invalid_gate_decision} =
             Engine.resolve_gate(turn_id, review_id, :ship, nil, [], engine)

    assert {:error, :gate_review_not_found} =
             Engine.resolve_gate(turn_id, "turn-1:stale:9", :approve, nil, [], engine)

    assert :ok =
             Engine.resolve_gate(
               turn_id,
               review_id,
               :approve,
               nil,
               ["Owner accepted the evidence"],
               engine
             )

    completed = wait_until_terminal(turn_id, engine)
    assert completed.status == :completed
    assert completed.squad.pending_review == nil
    assert completed.squad.latest_gate.actor == "human"
    assert completed.squad.latest_gate.role_id == "human_owner"

    event_types =
      EventStore.load(store)
      |> Enum.filter(&(&1.data["turn_id"] == turn_id))
      |> Enum.map(& &1.type)

    assert :gate_review_requested in event_types
    assert :gate_resolved in event_types
  end

  test "owner rework resolutions keep the squad alive when the budget is exhausted" do
    %{engine: engine, store: _store} =
      start_isolated_engine(
        squad_release_gate_human: true,
        simulator_opts: [delay_ms: 0, seed: 246, leader_rework_rounds: 4]
      )

    room_id = first_room_id(engine)
    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Exhaust the rework budget", :squad, engine)

    on_exit(fn ->
      case GenServer.whereis(engine) do
        pid when is_pid(pid) -> Engine.cancel_turn(turn_id, "test cleanup", engine)
        _ -> :ok
      end
    end)

    # Three rework cycles inside the budget plus one beyond it: each release-gate
    # rework recommendation is owner-reviewed, and the owner-approved rework
    # beyond the budget must extend it instead of silently failing the turn.
    Enum.each(1..4, fn cycle ->
      flush_projection_snapshots()

      turn = wait_until_pending_review(turn_id, engine)

      assert turn.status == :running
      assert turn.squad.rework_count == cycle - 1
      assert turn.squad.pending_review.decision == "rework"
      assert turn.squad.pending_review.cycle == cycle - 1

      assert :ok =
               Engine.resolve_gate(
                 turn_id,
                 turn.squad.pending_review.review_id,
                 :rework,
                 "integration",
                 ["owner approves cycle #{cycle}"],
                 engine
               )
    end)

    flush_projection_snapshots()

    final = wait_until_pending_review(turn_id, engine)
    assert final.squad.pending_review.decision == "approve"

    assert :ok =
             Engine.resolve_gate(
               turn_id,
               final.squad.pending_review.review_id,
               :approve,
               nil,
               ["owner approves release"],
               engine
             )

    completed = wait_until_terminal(turn_id, engine)
    assert completed.status == :completed

    # Four reworks happened: three budgeted plus one durably granted by the
    # owner beyond the budget (squad_budget_extended event).
    assert completed.squad.rework_count == 4
    assert completed.squad.rework_budget == 4
  end

  test "release authority is frozen at turn start" do
    # Ambient policy says leader authority; this engine's injected config says
    # human. The authority recorded at turn start ("human") must hold even
    # though nothing else in the environment agrees with it.
    %{engine: engine} = start_isolated_engine(squad_release_gate_human: true)
    room_id = first_room_id(engine)
    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, engine)

    assert {:ok, turn_id} = Engine.post_message(room_id, "Freeze the authority", :squad, engine)

    on_exit(fn -> ReyCode.cancel_turn(turn_id) end)
    assert RuntimeConfig.load!().squad_release_gate_human == false

    turn = wait_until_pending_review(turn_id, engine)
    assert turn.squad.release_authority == "human"
    assert turn.squad.pending_review.decision == "approve"

    assert :ok =
             Engine.resolve_gate(
               turn_id,
               turn.squad.pending_review.review_id,
               :approve,
               nil,
               ["owner approves release"],
               engine
             )

    assert wait_until_terminal(turn_id, engine).status == :completed
  end

  test "blocks a squad turn when required roles are unconfigured" do
    assert {:ok, room_id} = ReyCode.create_room("Unconfigured Squad", System.tmp_dir!())

    assert {:error, {:squad_roles_unconfigured, missing}} =
             ReyCode.post_message(room_id, "Do not start", :squad)

    assert length(missing) == 12
    assert "squad_leader" in missing
    assert ReyCode.snapshot().rooms[room_id].active_turn_id == nil
  end

  test "recovers an active squad phase without duplicating logical work" do
    %{engine: engine} =
      start_isolated_supervised_engine(simulator_opts: [delay_ms: 20, seed: 999])

    room_id = configure_squad(engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Recover this squad", :squad, engine)

    old_engine = Process.whereis(engine)
    assert is_pid(old_engine)
    Process.exit(old_engine, :kill)
    wait_for_new_engine(engine, old_engine, 200)

    turn = wait_until_terminal(turn_id, engine)
    snapshot = Engine.snapshot(engine)

    assert turn.status == :completed

    active_duplicates =
      turn.invocation_order
      |> Enum.map(&snapshot.invocations[&1])
      |> Enum.group_by(& &1.logical_work_id)
      |> Enum.filter(fn {_id, attempts} ->
        Enum.count(attempts, &(&1.status in [:queued, :running])) > 1
      end)

    assert active_duplicates == []
  end

  defp wait_until_terminal(turn_id, server, attempts \\ 3_000),
    do: Wait.terminal_turn(server, turn_id, attempts * 10)

  defp wait_until_pending_review(turn_id, server, attempts \\ 3_000),
    do: Wait.pending_review(server, turn_id, attempts * 10)

  defp first_room_id(server), do: Engine.snapshot(server).room_order |> hd()

  defp configure_squad(server) do
    room_id = first_room_id(server)
    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, server)
    room_id
  end

  defp start_isolated_engine(config_overrides) do
    {simulator_opts, config_overrides} = Keyword.pop(config_overrides, :simulator_opts)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_squad_eng_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    suffix = System.unique_integer([:positive])

    agent_registry = :"agent_#{suffix}"
    event_registry = :"events_#{suffix}"
    agent_supervisor = :"sup_#{suffix}"

    start_supervised!({Registry, keys: :unique, name: agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_supervisor})

    config =
      RuntimeConfig.load!()
      |> Map.from_struct()
      |> Map.merge(Map.new(config_overrides))
      |> then(&struct!(RuntimeConfig, &1))

    server = :"engine_#{suffix}"

    opts = [
      name: server,
      event_store: store,
      agent_supervisor: agent_supervisor,
      agent_registry: agent_registry,
      event_registry: event_registry,
      provider_catalog: ReyCode.Provider.Catalog,
      agent_delay_ms: 0,
      simulator_opts: simulator_opts,
      config: config
    ]

    start_supervised!(Supervisor.child_spec({Engine, opts}, restart: :temporary))

    %{engine: server, store: store}
  end

  defp start_isolated_supervised_engine(config_overrides) do
    {simulator_opts, config_overrides} = Keyword.pop(config_overrides, :simulator_opts)
    suffix = System.unique_integer([:positive])

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_squad_restart_#{System.pid()}_#{suffix}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    agent_registry = :"squad_restart_agents_#{suffix}"
    event_registry = :"squad_restart_events_#{suffix}"
    agent_supervisor = :"squad_restart_agent_sup_#{suffix}"
    server = :"squad_restart_engine_#{suffix}"

    start_supervised!({Registry, keys: :unique, name: agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: event_registry})

    config =
      RuntimeConfig.load!()
      |> Map.from_struct()
      |> Map.merge(Map.new(config_overrides))
      |> then(&struct!(RuntimeConfig, &1))

    supervisor_opts = [
      name: :"squad_restart_supervisor_#{suffix}",
      agent_supervisor: agent_supervisor,
      config: config,
      engine_opts: [
        name: server,
        event_store: store,
        agent_registry: agent_registry,
        event_registry: event_registry,
        provider_catalog: ReyCode.Provider.Catalog,
        agent_delay_ms: 20,
        simulator_opts: simulator_opts
      ]
    ]

    start_supervised!(
      Supervisor.child_spec(
        {ReyCode.Orchestration.Supervisor, supervisor_opts},
        restart: :temporary
      )
    )

    %{engine: server, store: store}
  end

  defp flush_projection_snapshots do
    receive do
      {:projection_snapshot, _projection} -> flush_projection_snapshots()
    after
      0 -> :ok
    end
  end

  defp wait_for_new_engine(_server, _old_engine, 0), do: flunk("engine did not restart")

  defp wait_for_new_engine(server, old_engine, attempts) do
    case Process.whereis(server) do
      pid when is_pid(pid) and pid != old_engine ->
        :ok

      _pid ->
        Process.sleep(10)
        wait_for_new_engine(server, old_engine, attempts - 1)
    end
  end
end
