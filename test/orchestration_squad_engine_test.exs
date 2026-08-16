defmodule ReyCode.Orchestration.SquadEngineTest do
  use ExUnit.Case, async: false

  alias ReyCode.EventStore
  alias ReyCode.Orchestration.{Engine, Projector, Squad}
  alias ReyCode.Test.Wait

  setup do
    previous = Application.get_env(:rey_code, :squad_simulator)
    Application.put_env(:rey_code, :squad_simulator, delay_ms: 0, seed: 123)
    room_id = ReyCode.snapshot().room_order |> hd()
    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil)

    on_exit(fn ->
      if previous do
        Application.put_env(:rey_code, :squad_simulator, previous)
      else
        Application.delete_env(:rey_code, :squad_simulator)
      end
    end)

    :ok
  end

  test "leader supervises the fixed workflow through architecture and release" do
    room_id = ReyCode.snapshot().room_order |> hd()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Deliver the squad workflow", :squad)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()
    invocations = Enum.map(turn.invocation_order, &snapshot.invocations[&1])

    assert turn.status == :completed
    assert turn.squad.workflow_version == "squad-v2"
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

    replayed = EventStore.load() |> Projector.replay()
    assert replayed.turns[turn_id] == snapshot.turns[turn_id]
  end

  test "leader rework returns to senior integration and completes" do
    Application.put_env(:rey_code, :squad_simulator,
      delay_ms: 0,
      seed: 456,
      leader_rework_rounds: 1
    )

    room_id = ReyCode.snapshot().room_order |> hd()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Exercise bounded rework", :squad)

    turn = wait_until_terminal(turn_id)

    assert turn.status == :completed
    assert turn.squad.rework_count == 1
    assert turn.squad.cycle == 1
    assert Enum.count(turn.squad.artifacts, &(&1.kind == "integrated_implementation")) == 2

    assert Enum.any?(EventStore.load(), fn event ->
             event.type == :squad_retry_scheduled and event.data["kind"] == "rework" and
               event.data["turn_id"] == turn_id
           end)
  end

  test "transient worker failures create a durable second attempt without duplicate work" do
    Application.put_env(:rey_code, :squad_simulator,
      delay_ms: 0,
      seed: 789,
      failure_plan: %{{"stories", "analyst", 1} => :retryable}
    )

    room_id = ReyCode.snapshot().room_order |> hd()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Exercise retry", :squad)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()

    analyst_attempts =
      turn.invocation_order
      |> Enum.map(&snapshot.invocations[&1])
      |> Enum.filter(&(&1.phase == "stories"))

    assert turn.status == :completed
    assert Enum.map(analyst_attempts, & &1.attempt) == [1, 2]
    assert Enum.uniq_by(analyst_attempts, & &1.logical_work_id) |> length() == 1
  end

  test "configures fixed squad role runtimes durably" do
    room_id = ReyCode.snapshot().room_order |> hd()

    assert :ok = Engine.configure_squad_roles(room_id, ["analyst", "architect"], :simulator, nil)
    room = ReyCode.snapshot().rooms[room_id]

    assert room.squad_roles["analyst"].provider == :simulator
    assert room.squad_roles["architect"].name == "Architect"
  end

  test "records an owner directive on a running squad turn" do
    Application.put_env(:rey_code, :squad_simulator, delay_ms: 1_000, seed: 321)
    room_id = ReyCode.snapshot().room_order |> hd()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Steer this squad", :squad)

    on_exit(fn -> ReyCode.cancel_turn(turn_id) end)

    assert :ok = ReyCode.direct_squad(turn_id, "Keep the first release read-only.")

    assert [directive] = ReyCode.snapshot().turns[turn_id].squad.directives
    assert directive.text == "Keep the first release read-only."
    assert directive.phase == "leader_intake"

    assert Enum.any?(EventStore.load(), fn event ->
             event.type == :squad_directive_added and event.data["turn_id"] == turn_id
           end)

    assert {:error, :empty_directive} = ReyCode.direct_squad(turn_id, "   ")
    assert :ok = ReyCode.cancel_turn(turn_id)
    assert {:error, :squad_not_running} = ReyCode.direct_squad(turn_id, "Too late")
  end

  test "holds the release gate for the owner and advances after approval" do
    previous = Application.get_env(:rey_code, :squad_release_gate_human)
    Application.put_env(:rey_code, :squad_release_gate_human, true)

    on_exit(fn -> Application.put_env(:rey_code, :squad_release_gate_human, previous) end)

    room_id = ReyCode.snapshot().room_order |> hd()

    assert {:ok, turn_id} =
             ReyCode.post_message(room_id, "Require owner release approval", :squad)

    turn = wait_until_pending_review(turn_id)
    assert turn.status == :running
    assert turn.squad.phase == "release_gate"
    assert turn.squad.pending_review.decision == "approve"
    assert turn.squad.pending_review.actor == "agent"
    refute Enum.any?(turn.squad.decisions, &(&1.phase == "release_gate"))

    assert {:error, :invalid_gate_decision} = ReyCode.resolve_gate(turn_id, :ship)
    assert :ok = ReyCode.resolve_gate(turn_id, :approve, nil, ["Owner accepted the evidence"])

    completed = wait_until_terminal(turn_id)
    assert completed.status == :completed
    assert completed.squad.pending_review == nil
    assert completed.squad.latest_gate.actor == "human"
    assert completed.squad.latest_gate.role_id == "human_owner"

    event_types =
      EventStore.load()
      |> Enum.filter(&(&1.data["turn_id"] == turn_id))
      |> Enum.map(& &1.type)

    assert :gate_review_requested in event_types
    assert :gate_resolved in event_types
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
    Application.put_env(:rey_code, :squad_simulator, delay_ms: 20, seed: 999)
    room_id = ReyCode.snapshot().room_order |> hd()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Recover this squad", :squad)

    old_engine = Process.whereis(Engine)
    assert is_pid(old_engine)
    Process.exit(old_engine, :kill)
    wait_for_new_engine(old_engine, 200)

    turn = wait_until_terminal(turn_id)
    snapshot = ReyCode.snapshot()

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

  defp wait_until_terminal(turn_id, attempts \\ 400),
    do: Wait.terminal_turn(Engine, turn_id, attempts * 10)

  defp wait_until_pending_review(turn_id, attempts \\ 400),
    do: Wait.pending_review(Engine, turn_id, attempts * 10)

  defp wait_for_new_engine(_old_engine, 0), do: flunk("engine did not restart")

  defp wait_for_new_engine(old_engine, attempts) do
    case Process.whereis(Engine) do
      pid when is_pid(pid) and pid != old_engine ->
        :ok

      _pid ->
        Process.sleep(10)
        wait_for_new_engine(old_engine, attempts - 1)
    end
  end
end
