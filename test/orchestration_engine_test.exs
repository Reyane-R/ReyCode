defmodule ReyCode.Orchestration.EngineTest do
  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, Projector, Squad}
  alias ReyCode.Orchestration.Engine.Lifecycle
  alias ReyCode.Orchestration.Supervisor, as: OrchestrationSupervisor
  alias ReyCode.Provider.Frame
  alias ReyCode.Test.Wait

  test "ordinary messages invoke only the primary assistant" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Handle this directly")

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    [invocation_id] = turn.invocation_order

    assert turn.mode == :direct
    assert snapshot.invocations[invocation_id].participant.kind == :primary
  end

  test "adds and persists a primary assistant when restoring a legacy room" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_primary_migration_#{System.unique_integer([:positive])}.sqlite3"
      )

    id = {EventStore, System.unique_integer([:positive])}
    spec = Supervisor.child_spec({EventStore, [name: nil, path: path]}, id: id)
    store = start_supervised!(spec)

    legacy_participant = %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "implementation",
      "provider" => "simulator",
      "model" => nil
    }

    assert {:ok, _event} =
             EventStore.append(
               :room_created,
               %{
                 "room_id" => "room-legacy",
                 "slug" => "legacy",
                 "title" => "Legacy",
                 "workspace" => System.tmp_dir!(),
                 "participants" => [legacy_participant]
               },
               store,
               aggregate_type: :room,
               aggregate_id: "room-legacy",
               room_id: "room-legacy"
             )

    state = %{
      projection: store |> EventStore.load() |> Projector.replay(),
      event_store: store,
      config: RuntimeConfig.fresh(allow_simulator_provider: true)
    }

    migrated = Lifecycle.ensure_primary_participants(state)

    assistant =
      Enum.find(migrated.projection.rooms["room-legacy"].participants, &(&1.kind == :primary))

    assert assistant.name == "Assistant"
    assert assistant.provider == :simulator

    stop_supervised!(id)
    restarted = start_supervised!(spec)
    replayed = restarted |> EventStore.load() |> Projector.replay()

    assert Enum.any?(replayed.rooms["room-legacy"].participants, &(&1.kind == :primary))
  end

  test "new sessions copy configured agent profiles without transcript history" do
    %{engine: engine} = start_isolated_engine([])
    source_room_id = default_room_id(engine)

    assert {:ok, task_participant_id} =
             Engine.add_task_participant(
               source_room_id,
               "Documentation",
               "Write and update project documentation",
               engine
             )

    assert :ok =
             Engine.configure_participants(
               source_room_id,
               task_participant_id,
               :simulator,
               nil,
               engine
             )

    assert {:ok, source_turn_id} =
             Engine.post_message(source_room_id, "Old transcript", :direct, engine)

    assert wait_until_terminal_on(engine, source_turn_id).outcome == :completed

    assert {:ok, session_id} = Engine.create_session(source_room_id, "Copy profiles", engine)

    snapshot = Engine.snapshot(engine)
    source = snapshot.rooms[source_room_id]
    session = snapshot.rooms[session_id]

    assert session.id != source.id
    assert session.workspace == source.workspace
    assert session.message_order == []

    assert Enum.map(session.participants, &{&1.id, &1.kind, &1.provider, &1.model}) ==
             Enum.map(source.participants, &{&1.id, &1.kind, &1.provider, &1.model})
  end

  test "owner commands run bash and post a durable transcript message" do
    %{engine: engine} = start_isolated_engine([])
    room_id = default_room_id(engine)

    assert :ok = Engine.run_owner_command(room_id, "echo reycode-owner", engine)

    projection =
      Wait.projection(engine, fn projection ->
        if Enum.any?(projection.rooms[room_id].message_order, fn message_id ->
             String.contains?(projection.messages[message_id].body || "", "reycode-owner")
           end),
           do: projection
      end)

    [message_id] = projection.rooms[room_id].message_order
    body = projection.messages[message_id].body

    assert body =~ "! echo reycode-owner"
    assert body =~ "reycode-owner"
    assert projection.messages[message_id].status == :completed

    assert {:error, :empty_command} = Engine.run_owner_command(room_id, "   ", engine)
    assert {:error, :room_not_found} = Engine.run_owner_command("missing", "echo x", engine)
  end

  test "created task agents run only when explicitly delegated" do
    %{engine: engine} = start_isolated_engine([])
    room_id = default_room_id(engine)

    assert {:ok, participant_id} =
             Engine.add_task_participant(
               room_id,
               "Release",
               "Commit, push, and deploy approved changes",
               engine
             )

    assert :ok =
             Engine.configure_participants(room_id, participant_id, :simulator, nil, engine)

    assert {:ok, turn_id} =
             Engine.delegate_task(room_id, participant_id, "Deploy the current release", engine)

    turn = wait_until_terminal_on(engine, turn_id)
    snapshot = Engine.snapshot(engine)
    [invocation_id] = turn.invocation_order

    assert turn.mode == :delegate
    assert turn.participant_id == participant_id
    assert snapshot.invocations[invocation_id].participant.id == participant_id
    assert snapshot.invocations[invocation_id].participant.model == nil
  end

  test "advanced compare invokes only participants explicitly present in the room" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "How should this ship?", :compare)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    room = snapshot.rooms[room_id]
    messages = Enum.map(room.message_order, &snapshot.messages[&1])

    assert turn.outcome == :completed
    assert Enum.count(messages, &(&1.turn_id == turn_id)) == 2
    assert Enum.count(messages, &(&1.role == :assistant and &1.turn_id == turn_id)) == 1
  end

  test "debate schedules proposal, critiques, and revision in durable stages" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Choose an event model", :debate)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.outcome == :completed
    assert Enum.map(invocations, & &1.phase_index) == [0, 2]
    assert Enum.map(invocations, & &1.label) == ["proposal", "revision"]
  end

  test "fan-out records independent parallel branches" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Explore three designs", :fan_out)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.outcome == :completed
    assert length(invocations) == 1
    assert Enum.all?(invocations, &(&1.label == "parallel branch"))
  end

  test "creates project rooms and queues follow-up turns FIFO" do
    assert {:ok, room_id} = ReyCode.create_room("Payments Rewrite", System.tmp_dir!())
    assert {:ok, first_id} = ReyCode.post_message(room_id, "First question", :compare)
    assert {:ok, second_id} = ReyCode.post_message(room_id, "Follow-up question", :compare)

    first = wait_until_terminal(first_id)
    second = wait_until_terminal(second_id)
    snapshot = ReyCode.snapshot()

    assert first.outcome == :completed
    assert second.outcome == :completed
    assert snapshot.rooms[room_id].slug == "payments-rewrite"
    assert snapshot.rooms[room_id].active_turn_id == nil
    assert snapshot.rooms[room_id].queued_turn_ids == []
  end

  test "accepts an in-flight duplicate frame retry idempotently" do
    %{engine: engine} = start_isolated_engine(agent_delay_ms: 100)

    room_id = default_room_id(engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Retry one durable frame", :compare, engine)

    invocation = wait_for_frame_on(engine, turn_id)
    message = Engine.snapshot(engine).messages[invocation.message_id]

    duplicate = Frame.text_delta(invocation.last_frame_sequence, "conflicting retry")

    assert :ok = Engine.Client.record_frame(engine, invocation.id, duplicate)
    assert Engine.snapshot(engine).messages[invocation.message_id].body == message.body
    assert wait_until_terminal_on(engine, turn_id).outcome == :completed
  end

  test "persists provider frames before terminal invocation events" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Durable frame check", :compare)
    turn = wait_until_terminal(turn_id)
    events = EventStore.load()

    Enum.each(turn.invocation_order, fn invocation_id ->
      frame_sequences =
        for event <- events,
            event.type == :provider_frame_recorded,
            event.data["invocation_id"] == invocation_id,
            do: event.sequence

      terminal =
        Enum.find(events, fn event ->
          event.type in [:invocation_completed, :invocation_failed] and
            event.data["invocation_id"] == invocation_id
        end)

      assert frame_sequences != []
      assert Enum.all?(frame_sequences, &(&1 < terminal.sequence))
    end)

    assert ReyCode.snapshot() == Projector.replay(events)
  end

  test "rejects an OpenCode model when provider discovery is unavailable" do
    assert {:ok, room_id} = ReyCode.create_room("Provider Assignment", System.tmp_dir!())

    assert {:error, :unchecked} =
             ReyCode.configure_participants(
               room_id,
               ["assistant"],
               :opencode,
               "openai/gpt-5.6-sol"
             )

    assert Enum.all?(ReyCode.snapshot().rooms[room_id].participants, &(&1.provider == :simulator))
  end

  @tag capture_log: true
  test "recovers an active room turn after the engine is killed" do
    %{engine: engine} = start_isolated_supervision(agent_delay_ms: 100)

    Engine.subscribe(engine)
    old_engine = Process.whereis(engine)
    room_id = default_room_id(engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Recover this room", :compare, engine)
    baseline = Engine.snapshot(engine).sequence
    flush_projection_snapshots()

    monitor = Process.monitor(old_engine)
    Process.exit(old_engine, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_engine, :killed}, 1_000
    assert wait_for_engine(engine, old_engine)

    assert wait_until_terminal_on(engine, turn_id).outcome == :completed
    assert receive_snapshot_after(baseline)
  end

  @tag capture_log: true
  test "records a worker crash and allows the turn to finish" do
    %{engine: engine, agent_registry: agent_registry} =
      start_isolated_engine(agent_delay_ms: 100)

    room_id = default_room_id(engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Survive one worker crash", :compare, engine)

    turn = Engine.snapshot(engine).turns[turn_id]
    invocation_id = hd(turn.invocation_order)
    {pid, _value} = Wait.registry_entry(agent_registry, invocation_id)
    Process.exit(pid, :kill)

    terminal = wait_until_terminal_on(engine, turn_id, 5_000)
    assert terminal.outcome == :failed
    assert Engine.snapshot(engine).invocations[invocation_id].error.category == :worker_exit
  end

  @tag capture_log: true
  test "records frames emitted from a helper task process" do
    %{engine: engine} =
      start_isolated_engine(simulator_opts: [seed: 5, delay_ms: 0, emit_process: :task])

    room_id = default_room_id(engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Frames from a task process", :compare, engine)

    turn = wait_until_terminal_on(engine, turn_id)
    snapshot = Engine.snapshot(engine)
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.outcome == :completed

    assert Enum.all?(invocations, fn invocation ->
             invocation.status == :completed and invocation.last_frame_sequence > 0
           end)
  end

  @tag capture_log: true
  test "restarts Engine when its AgentSupervisor dependency crashes" do
    old_engine = Process.whereis(Engine)
    old_supervisor = Process.whereis(ReyCode.AgentSupervisor)
    engine_monitor = Process.monitor(old_engine)
    supervisor_monitor = Process.monitor(old_supervisor)

    Process.exit(old_supervisor, :kill)

    assert_receive {:DOWN, ^supervisor_monitor, :process, ^old_supervisor, :killed}, 1_000
    assert_receive {:DOWN, ^engine_monitor, :process, ^old_engine, :shutdown}, 1_000
    assert wait_for_engine(old_engine)
    refute Process.whereis(ReyCode.AgentSupervisor) == old_supervisor
  end

  describe "record_frames batches" do
    setup do
      {:ok, start_isolated_engine(agent_delay_ms: 200)}
    end

    test "accepts empty batches and rejects unknown invocations and non-list frames", %{
      engine: engine
    } do
      room_id = default_room_id(engine)

      assert {:ok, turn_id} =
               Engine.post_message(room_id, "Batch validation check", :compare, engine)

      invocation = wait_for_running(engine, turn_id)

      assert :ok = Engine.Client.record_frames(engine, invocation.id, [])
      assert {:error, :invocation_not_found} = Engine.Client.record_frames(engine, "inv-x", [])

      assert {:error, :invalid_frames} =
               GenServer.call(engine, {:record_frames, invocation.id, :junk})

      drain_turn(engine, turn_id)
    end

    test "rejects batches containing non-frame elements without crashing the engine", %{
      engine: engine
    } do
      room_id = default_room_id(engine)

      assert {:ok, turn_id} =
               Engine.post_message(room_id, "Non-frame batch check", :compare, engine)

      invocation = wait_for_running(engine, turn_id)

      assert {:error, :invalid_frame} =
               Engine.Client.record_frames(engine, invocation.id, [:junk])

      updated = Engine.snapshot(engine).invocations[invocation.id]

      assert :ok =
               Engine.Client.record_frames(engine, invocation.id, [
                 Frame.text_delta(updated.last_frame_sequence + 1, "engine still alive")
               ])

      assert Engine.snapshot(engine).invocations[invocation.id].last_frame_sequence >=
               updated.last_frame_sequence + 1

      drain_turn(engine, turn_id)
    end

    test "appends contiguous batches, subsumes duplicates, and rejects gaps and invalid frames",
         %{
           engine: engine
         } do
      room_id = default_room_id(engine)
      assert {:ok, turn_id} = Engine.post_message(room_id, "Batch append check", :compare, engine)
      invocation = wait_for_running(engine, turn_id)

      assert invocation.last_frame_sequence == 0

      assert :ok =
               Engine.Client.record_frames(engine, invocation.id, [
                 Frame.text_delta(1, "first"),
                 Frame.text_delta(2, "second")
               ])

      assert Engine.snapshot(engine).invocations[invocation.id].last_frame_sequence == 2

      assert :ok =
               Engine.Client.record_frames(engine, invocation.id, [
                 Frame.text_delta(2, "duplicate"),
                 Frame.text_delta(3, "third")
               ])

      updated = Engine.snapshot(engine).invocations[invocation.id]
      assert updated.last_frame_sequence == 3

      assert {:error, :invalid_frame_sequence} =
               Engine.Client.record_frames(engine, invocation.id, [
                 Frame.text_delta(updated.last_frame_sequence + 2, "gap")
               ])

      assert {:error, :invalid_frame} =
               Engine.Client.record_frames(engine, invocation.id, [
                 %Frame{
                   sequence: updated.last_frame_sequence + 1,
                   kind: :text_delta,
                   data: %{text: 7}
                 }
               ])

      drain_turn(engine, turn_id)
    end

    test "rejects frame batches for a terminal invocation", %{engine: engine} do
      room_id = default_room_id(engine)

      assert {:ok, turn_id} =
               Engine.post_message(room_id, "Terminal batch check", :compare, engine)

      invocation = wait_for_running(engine, turn_id)

      drain_turn(engine, turn_id)

      final = Engine.snapshot(engine).invocations[invocation.id]
      assert final.status == :completed

      assert {:error, :invocation_terminal} =
               Engine.Client.record_frames(engine, invocation.id, [
                 Frame.text_delta(final.last_frame_sequence + 1, "late")
               ])
    end
  end

  test "rejects malformed commands at the clause boundary without touching state" do
    %{engine: engine} = start_isolated_engine([])
    room_id = default_room_id(engine)

    assert {:error, :room_not_found} =
             Engine.post_message("room-missing", "Hello", :compare, engine)

    assert {:error, :invalid_mode} = Engine.post_message(room_id, "Hello", :unknown_mode, engine)

    assert {:error, :invocation_not_found} =
             Engine.Client.record_round(engine, "inv-missing", 0, %{"text" => ""})

    assert {:error, :invocation_not_found} = Engine.Client.take_tool_run(engine, "inv-missing")

    assert {:error, :invocation_not_found} =
             Engine.Client.record_frame(engine, "inv-missing", Frame.text_delta(1, "late"))

    assert {:error, :invocation_not_found} =
             Engine.Client.tool_run_started(engine, "inv-missing", "run-missing")
  end

  defp wait_for_running(engine, turn_id, timeout \\ 3_000) do
    Wait.projection(
      engine,
      &find_running_invocation(&1, turn_id),
      timeout
    )
  end

  defp find_running_invocation(projection, turn_id) do
    case projection.turns[turn_id] do
      nil -> nil
      turn -> Enum.find_value(turn.invocation_order, &lookup_running(projection, &1))
    end
  end

  defp lookup_running(projection, invocation_id) do
    case projection.invocations[invocation_id] do
      %{status: :running} = invocation -> invocation
      _other -> nil
    end
  end

  defp drain_turn(engine, turn_id),
    do: assert(wait_until_terminal_on(engine, turn_id).outcome == :completed)

  defp default_room_id(engine \\ Engine) do
    snapshot = Engine.snapshot(engine)
    Enum.find(snapshot.room_order, &(snapshot.rooms[&1].slug == "reycode"))
  end

  defp wait_until_terminal(turn_id, attempts \\ 300) when is_integer(attempts),
    do: Wait.terminal_turn(Engine, turn_id, attempts * 10)

  defp wait_until_terminal_on(engine, turn_id, timeout \\ 3_000),
    do: Wait.terminal_turn(engine, turn_id, timeout)

  defp wait_for_frame_on(engine, turn_id) do
    Wait.projection(engine, &streaming_invocation(&1, turn_id), 3_000)
  end

  defp streaming_invocation(projection, turn_id) do
    turn = projection.turns[turn_id]
    turn && Enum.find_value(turn.invocation_order, &running_invocation(projection, &1))
  end

  defp running_invocation(projection, invocation_id) do
    case projection.invocations[invocation_id] do
      %{status: :running, last_frame_sequence: sequence} = invocation when sequence > 0 ->
        invocation

      _invocation ->
        nil
    end
  end

  defp wait_for_engine(name, old_engine, attempts \\ 100)
  defp wait_for_engine(_name, _old_engine, 0), do: false

  defp wait_for_engine(name, old_engine, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_engine ->
        true

      _ ->
        Process.sleep(10)
        wait_for_engine(name, old_engine, attempts - 1)
    end
  end

  defp wait_for_engine(old_engine), do: wait_for_engine(Engine, old_engine)

  defp start_isolated_engine(options) do
    stack = stack_options(options)
    stack = start_stack_dependencies(stack)

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: stack.agent_supervisor})
    start_supervised!({Task.Supervisor, name: stack.task_supervisor})
    start_supervised!({Engine, engine_options(stack)})
    Map.take(stack, [:engine, :store, :agent_registry])
  end

  defp start_isolated_supervision(options) do
    stack = stack_options(options)
    stack = start_stack_dependencies(stack)

    start_supervised!(
      {OrchestrationSupervisor,
       name: stack.supervisor,
       agent_supervisor: stack.agent_supervisor,
       config: stack.config,
       engine_opts: engine_options(stack)}
    )

    Map.take(stack, [:engine, :store, :agent_registry])
  end

  defp stack_options(options) do
    suffix = System.unique_integer([:positive])
    {agent_delay_ms, options} = Keyword.pop(options, :agent_delay_ms, 0)
    {simulator_opts, config_options} = Keyword.pop(options, :simulator_opts, [])

    config =
      RuntimeConfig.fresh(
        Keyword.merge(
          [
            allow_simulator_provider: true,
            default_provider: :simulator,
            provider_discovery: false
          ],
          config_options
        )
      )

    %{
      config: config,
      agent_delay_ms: agent_delay_ms,
      simulator_opts: simulator_opts,
      store_path:
        Path.join(System.tmp_dir!(), "rey_code_engine_#{System.pid()}_#{suffix}.sqlite3"),
      store: nil,
      agent_registry: :"engine_test_agents_#{suffix}",
      event_registry: :"engine_test_events_#{suffix}",
      agent_supervisor: :"engine_test_agent_sup_#{suffix}",
      task_supervisor: :"engine_test_tasks_#{suffix}",
      engine: :"engine_test_engine_#{suffix}",
      supervisor: :"engine_test_sup_#{suffix}"
    }
  end

  defp start_stack_dependencies(stack) do
    store =
      start_supervised!(
        {EventStore, name: nil, path: stack.store_path, config: stack.config.persistence}
      )

    start_supervised!({Registry, keys: :unique, name: stack.agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: stack.event_registry})
    %{stack | store: store}
  end

  defp engine_options(stack) do
    [
      name: stack.engine,
      event_store: stack.store,
      agent_supervisor: stack.agent_supervisor,
      agent_registry: stack.agent_registry,
      event_registry: stack.event_registry,
      task_supervisor: stack.task_supervisor,
      provider_catalog: ReyCode.Provider.Catalog,
      agent_delay_ms: stack.agent_delay_ms,
      simulator_opts: stack.simulator_opts,
      config: stack.config
    ]
  end

  describe "projection transaction batches" do
    test "room creation publishes exactly one snapshot containing the room" do
      %{engine: engine} = start_isolated_engine(agent_delay_ms: 5_000)
      baseline = Engine.subscribe(engine)

      assert {:ok, room_id} = Engine.create_room("Batched room", System.tmp_dir!(), engine)

      assert [snapshot] = new_snapshots()
      assert snapshot.sequence > baseline.sequence
      assert Map.has_key?(snapshot.rooms, room_id)
    end

    test "a turn queued behind an active turn publishes its message and turn in one snapshot" do
      %{engine: engine} = start_isolated_engine(agent_delay_ms: 5_000)
      room_id = default_room_id(engine)
      Engine.subscribe(engine)

      assert {:ok, _occupied_turn} =
               Engine.post_message(room_id, "Occupy the room", :direct, engine)

      poll_projection(engine, fn snapshot ->
        if snapshot.rooms[room_id].active_turn_id, do: :ok
      end)

      flush_projection_snapshots()

      assert {:ok, queued_turn_id} =
               Engine.post_message(room_id, "Second while busy", :compare, engine)

      # Snapshots are cumulative, so the regression signal is referential:
      # the snapshot carrying the queued message must carry its turn too,
      # never the message alone.
      assert [snapshot | _rest] = new_snapshots()

      refute is_nil(snapshot.turns[queued_turn_id])

      refute is_nil(
               Enum.find(snapshot.messages, fn {_id, message} ->
                 message.turn_id == queued_turn_id
               end)
             )

      assert referentially_consistent?(snapshot)
    end

    test "cancellation publishes the cancelled invocation and terminal turn in one snapshot" do
      %{engine: engine} = start_isolated_engine(agent_delay_ms: 5_000)
      room_id = default_room_id(engine)
      Engine.subscribe(engine)

      assert {:ok, turn_id} = Engine.post_message(room_id, "Cancel me", :direct, engine)

      poll_projection(engine, &find_running_invocation(&1, turn_id))
      flush_projection_snapshots()

      assert :ok = Engine.cancel_turn(turn_id, "owner stop", engine)

      assert [snapshot] = new_snapshots()
      turn = snapshot.turns[turn_id]

      assert turn.status == :terminal
      assert turn.outcome == :cancelled

      statuses =
        Enum.map(turn.invocation_order, &snapshot.invocations[&1].status)

      assert Enum.all?(statuses, &(&1 == :cancelled))
    end

    test "every published snapshot during a full compare turn stays transaction-consistent" do
      %{engine: engine} = start_isolated_engine(agent_delay_ms: 0)
      Engine.subscribe(engine)
      room_id = default_room_id(engine)

      assert {:ok, turn_id} =
               Engine.post_message(room_id, "Compare these drafts", :compare, engine)

      snapshots = collect_snapshots_until(&turn_terminal?(&1, turn_id))
      assert Enum.all?(snapshots, &referentially_consistent?/1)

      user_message_id =
        case Engine.snapshot(engine).turns[turn_id] do
          %{user_message_id: message_id} -> message_id
        end

      assert Enum.any?(snapshots, fn snapshot ->
               Map.has_key?(snapshot.messages, user_message_id) and
                 Map.has_key?(snapshot.turns, turn_id)
             end)

      final_snapshot = Enum.reverse(snapshots) |> hd()
      assert final_snapshot == Engine.snapshot(engine)
    end

    test "squad stage and gate transitions publish transaction-consistent snapshots" do
      %{engine: engine} =
        start_isolated_engine(agent_delay_ms: 0, simulator_opts: [delay_ms: 0, seed: 123])

      room_id = default_room_id(engine)
      role_ids = Enum.map(Squad.roles(), & &1.id)

      assert :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, engine)
      Engine.subscribe(engine)

      assert {:ok, turn_id} =
               Engine.post_message(room_id, "Run the squad workflow", :squad, engine)

      # The human-owned release gate parks the turn on a pending review.
      pre_gate = collect_snapshots_until(&pending_gate_review?(&1, turn_id))
      assert Enum.all?(pre_gate, &referentially_consistent?/1)

      %{id: review_id} = Engine.snapshot(engine).turns[turn_id].squad.pending_review
      assert :ok = Engine.resolve_gate(turn_id, review_id, :approve, nil, [], engine)

      post_gate = collect_snapshots_until(&turn_terminal?(&1, turn_id))

      assert Enum.all?(pre_gate ++ post_gate, &referentially_consistent?/1)

      assert Enum.any?(post_gate, fn snapshot ->
               case snapshot.turns[turn_id] do
                 %{status: :terminal, outcome: :completed} -> true
                 _other -> false
               end
             end)
    end
  end

  defp new_snapshots(collected \\ []) do
    receive do
      {:projection_snapshot, snapshot} -> new_snapshots([snapshot | collected])
    after
      100 -> Enum.reverse(collected)
    end
  end

  # Blocking collection keeps every broadcast and stops at the first snapshot
  # matching the predicate, so assertions see the full published history.
  defp collect_snapshots_until(matcher, timeout \\ 15_000) do
    collect_snapshots_until(matcher, deadline(timeout), [])
  end

  defp collect_snapshots_until(matcher, deadline, collected) do
    receive do
      {:projection_snapshot, snapshot} ->
        collected = [snapshot | collected]

        if matcher.(snapshot) do
          Enum.reverse(collected)
        else
          collect_snapshots_until(matcher, deadline, collected)
        end
    after
      remaining = max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("timed out collecting projection snapshots: #{remaining}")
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp turn_terminal?(projection, turn_id),
    do: match?(%{status: :terminal}, projection.turns[turn_id])

  defp pending_gate_review?(projection, turn_id) do
    case projection.turns[turn_id] do
      %{squad: %{pending_review: review}} when not is_nil(review) -> true
      _other -> false
    end
  end

  # Polling reads the projection directly so the test's mailbox keeps every
  # published broadcast intact for subsequent consistency assertions.
  defp poll_projection(engine, matcher, attempts \\ 300)

  defp poll_projection(_engine, _matcher, 0), do: flunk("projection condition was not met")

  defp poll_projection(engine, matcher, attempts) do
    case matcher.(Engine.snapshot(engine)) do
      nil ->
        Process.sleep(10)
        poll_projection(engine, matcher, attempts - 1)

      result ->
        result
    end
  end

  defp referentially_consistent?(projection) do
    turn_ids = MapSet.new(Map.keys(projection.turns))

    messages_attached? =
      Enum.all?(projection.messages, fn {_id, message} ->
        message.turn_id == nil or MapSet.member?(turn_ids, message.turn_id)
      end)

    invocations_attached? =
      Enum.all?(projection.invocations, fn {_id, invocation} ->
        MapSet.member?(turn_ids, invocation.turn_id) and
          Map.has_key?(projection.messages, invocation.message_id)
      end)

    rooms_attached? =
      Enum.all?(projection.rooms, fn {_id, room} ->
        active_attached? =
          room.active_turn_id == nil or MapSet.member?(turn_ids, room.active_turn_id)

        queued_attached? = Enum.all?(room.queued_turn_ids, &MapSet.member?(turn_ids, &1))
        active_attached? and queued_attached?
      end)

    messages_attached? and invocations_attached? and rooms_attached?
  end

  defp flush_projection_snapshots do
    receive do
      {:projection_snapshot, _projection} -> flush_projection_snapshots()
    after
      0 -> :ok
    end
  end

  defp receive_snapshot_after(sequence) do
    receive do
      {:projection_snapshot, %{sequence: next}} when next > sequence -> true
      {:projection_snapshot, _projection} -> receive_snapshot_after(sequence)
    after
      1_000 -> false
    end
  end
end
