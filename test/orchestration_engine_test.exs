defmodule ReyCode.Orchestration.EngineTest do
  use ExUnit.Case, async: false

  alias ReyCode.EventStore
  alias ReyCode.Orchestration.{Engine, Projector}
  alias ReyCode.Provider.Frame
  alias ReyCode.Test.Wait

  test "compare posts durable parallel agent messages into a project room" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "How should this ship?", :compare)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    room = snapshot.rooms[room_id]
    messages = Enum.map(room.message_order, &snapshot.messages[&1])

    assert turn.status == :completed
    assert Enum.count(messages, &(&1.turn_id == turn_id)) == 4
    assert Enum.count(messages, &(&1.role == :assistant and &1.turn_id == turn_id)) == 3
    assert Enum.any?(messages, &String.contains?(&1.body, "smallest end-to-end implementation"))
  end

  test "debate schedules proposal, critiques, and revision in durable stages" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Choose an event model", :debate)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.status == :completed
    assert Enum.map(invocations, & &1.stage) == [0, 1, 1, 2]
    assert Enum.map(invocations, & &1.label) == ["proposal", "critique", "critique", "revision"]
  end

  test "fan-out records independent parallel branches" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Explore three designs", :fan_out)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.status == :completed
    assert length(invocations) == 3
    assert Enum.all?(invocations, &(&1.label == "parallel branch"))
  end

  test "creates project rooms and queues follow-up turns FIFO" do
    previous_delay = Application.get_env(:rey_code, :agent_delay_ms)
    Application.put_env(:rey_code, :agent_delay_ms, 5)
    on_exit(fn -> Application.put_env(:rey_code, :agent_delay_ms, previous_delay) end)

    assert {:ok, room_id} = ReyCode.create_room("Payments Rewrite", System.tmp_dir!())
    assert {:ok, first_id} = ReyCode.post_message(room_id, "First question", :compare)
    assert {:ok, second_id} = ReyCode.post_message(room_id, "Follow-up question", :compare)

    first = wait_until_terminal(first_id)
    second = wait_until_terminal(second_id)
    snapshot = ReyCode.snapshot()

    assert first.status == :completed
    assert second.status == :completed
    assert snapshot.rooms[room_id].slug == "payments-rewrite"
    assert snapshot.rooms[room_id].active_turn_id == nil
    assert snapshot.rooms[room_id].queued_turn_ids == []
  end

  test "accepts an in-flight duplicate frame retry idempotently" do
    previous_delay = Application.get_env(:rey_code, :agent_delay_ms)
    Application.put_env(:rey_code, :agent_delay_ms, 100)
    on_exit(fn -> Application.put_env(:rey_code, :agent_delay_ms, previous_delay) end)

    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Retry one durable frame", :compare)
    invocation = wait_for_frame(turn_id)
    message = ReyCode.snapshot().messages[invocation.message_id]

    duplicate = Frame.text_delta(invocation.last_frame_sequence, "conflicting retry")

    assert :ok = Engine.Client.record_frame(Engine, invocation.id, duplicate)
    assert ReyCode.snapshot().messages[invocation.message_id].body == message.body
    assert wait_until_terminal(turn_id).status == :completed
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
               ["builder", "critic"],
               :opencode,
               "openai/gpt-5.6-sol"
             )

    assert Enum.all?(ReyCode.snapshot().rooms[room_id].participants, &(&1.provider == :simulator))
  end

  @tag capture_log: true
  test "recovers an active room turn after the engine is killed" do
    previous_delay = Application.get_env(:rey_code, :agent_delay_ms)
    Application.put_env(:rey_code, :agent_delay_ms, 10)
    on_exit(fn -> Application.put_env(:rey_code, :agent_delay_ms, previous_delay) end)

    Engine.subscribe()
    old_engine = Process.whereis(Engine)
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Recover this room", :compare)
    baseline = ReyCode.snapshot().sequence
    flush_projection_snapshots()

    monitor = Process.monitor(old_engine)
    Process.exit(old_engine, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_engine, :killed}, 1_000
    assert wait_for_engine(old_engine)

    assert wait_until_terminal(turn_id).status == :completed
    assert receive_snapshot_after(baseline)
  end

  @tag capture_log: true
  test "records a worker crash and allows the turn to finish" do
    previous_delay = Application.get_env(:rey_code, :agent_delay_ms)
    Application.put_env(:rey_code, :agent_delay_ms, 100)
    on_exit(fn -> Application.put_env(:rey_code, :agent_delay_ms, previous_delay) end)

    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Survive one worker crash", :compare)
    turn = ReyCode.snapshot().turns[turn_id]
    invocation_id = hd(turn.invocation_order)
    [{pid, _value}] = Registry.lookup(ReyCode.AgentRegistry, invocation_id)
    Process.exit(pid, :kill)

    terminal = wait_until_terminal(turn_id, 500)
    assert terminal.status == :partial
    assert ReyCode.snapshot().invocations[invocation_id].error["category"] == "worker_exit"
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
      previous_delay = Application.get_env(:rey_code, :agent_delay_ms)
      Application.put_env(:rey_code, :agent_delay_ms, 1_000)
      on_exit(fn -> Application.put_env(:rey_code, :agent_delay_ms, previous_delay) end)
      :ok
    end

    test "accepts empty batches and rejects unknown invocations and non-list frames" do
      room_id = default_room_id()
      assert {:ok, turn_id} = ReyCode.post_message(room_id, "Batch validation check", :compare)
      invocation = wait_for_running(turn_id)

      assert :ok = Engine.Client.record_frames(Engine, invocation.id, [])
      assert {:error, :invocation_not_found} = Engine.Client.record_frames(Engine, "inv-x", [])

      assert {:error, :invalid_frames} =
               GenServer.call(Engine, {:record_frames, invocation.id, :junk})

      drain_turn(turn_id)
    end

    test "appends contiguous batches, subsumes duplicates, and rejects gaps and invalid frames" do
      room_id = default_room_id()
      assert {:ok, turn_id} = ReyCode.post_message(room_id, "Batch append check", :compare)
      invocation = wait_for_running(turn_id)

      assert invocation.last_frame_sequence == 0

      assert :ok =
               Engine.Client.record_frames(Engine, invocation.id, [
                 Frame.text_delta(1, "first"),
                 Frame.text_delta(2, "second")
               ])

      assert ReyCode.snapshot().invocations[invocation.id].last_frame_sequence == 2

      assert :ok =
               Engine.Client.record_frames(Engine, invocation.id, [
                 Frame.text_delta(2, "duplicate"),
                 Frame.text_delta(3, "third")
               ])

      updated = ReyCode.snapshot().invocations[invocation.id]
      assert updated.last_frame_sequence == 3

      assert {:error, :invalid_frame_sequence} =
               Engine.Client.record_frames(Engine, invocation.id, [
                 Frame.text_delta(updated.last_frame_sequence + 2, "gap")
               ])

      assert {:error, :invalid_frame} =
               Engine.Client.record_frames(Engine, invocation.id, [
                 %Frame{
                   sequence: updated.last_frame_sequence + 1,
                   kind: :text_delta,
                   data: %{text: 7}
                 }
               ])

      drain_turn(turn_id)
    end

    test "rejects frame batches for a terminal invocation" do
      room_id = default_room_id()
      assert {:ok, turn_id} = ReyCode.post_message(room_id, "Terminal batch check", :compare)
      invocation = wait_for_running(turn_id)

      drain_turn(turn_id)

      final = ReyCode.snapshot().invocations[invocation.id]
      assert final.status == :completed

      assert {:error, :invocation_terminal} =
               Engine.Client.record_frames(Engine, invocation.id, [
                 Frame.text_delta(final.last_frame_sequence + 1, "late")
               ])
    end
  end

  defp wait_for_running(turn_id, attempts \\ 300) do
    Wait.projection(
      Engine,
      fn projection ->
        turn = projection.turns[turn_id]

        turn &&
          Enum.find_value(turn.invocation_order, fn id ->
            case projection.invocations[id] do
              %{status: :running} = invocation -> invocation
              _other -> nil
            end
          end)
      end,
      attempts * 10
    )
  end

  defp drain_turn(turn_id) do
    Application.put_env(:rey_code, :agent_delay_ms, 5)
    assert wait_until_terminal(turn_id).status == :completed
  end

  defp default_room_id do
    snapshot = ReyCode.snapshot()
    Enum.find(snapshot.room_order, &(snapshot.rooms[&1].slug == "reycode"))
  end

  defp wait_until_terminal(turn_id, attempts \\ 300),
    do: Wait.terminal_turn(Engine, turn_id, attempts * 10)

  defp wait_for_frame(turn_id, attempts \\ 300) do
    Wait.projection(
      Engine,
      &streaming_invocation(&1, turn_id),
      attempts * 10
    )
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

  defp wait_for_engine(old_engine, attempts \\ 100)
  defp wait_for_engine(_old_engine, 0), do: false

  defp wait_for_engine(old_engine, attempts) do
    case Process.whereis(Engine) do
      pid when is_pid(pid) and pid != old_engine ->
        true

      _ ->
        Process.sleep(10)
        wait_for_engine(old_engine, attempts - 1)
    end
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
