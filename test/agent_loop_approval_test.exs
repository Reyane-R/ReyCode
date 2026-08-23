defmodule ReyCode.AgentLoopApprovalTest do
  @moduledoc """
  Durable tool-approval lifecycle contracts.

  Locks the acceptance matrix for approvals: approve executes the exact
  persisted request once and resumes the conversation; deny performs no side
  effect and finalizes through the normal workflow; both survive a complete
  engine restart; cancelling a turn cancels waiting approvals; and a waiting
  approval consumes no admission slot.
  """

  use ExUnit.Case, async: false

  alias ReyCode.EventStore
  alias ReyCode.Orchestration.{Engine, Squad}
  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "rey_code_approval_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    workspace_a = Path.join(base, "room-a")
    workspace_b = Path.join(base, "room-b")
    File.mkdir_p!(workspace_a)
    File.mkdir_p!(workspace_b)

    previous_simulator = Application.get_env(:rey_code, :squad_simulator)

    on_exit(fn ->
      File.rm_rf!(base)

      if previous_simulator do
        Application.put_env(:rey_code, :squad_simulator, previous_simulator)
      else
        Application.delete_env(:rey_code, :squad_simulator)
      end
    end)

    %{workspace_a: workspace_a, workspace_b: workspace_b}
  end

  defp engine_opts(store, extra \\ []) do
    [
      name: @engine,
      event_store: store,
      agent_supervisor: @agent_supervisor,
      agent_registry: @agent_registry,
      event_registry: @event_registry,
      provider_catalog: ReyCode.Provider.Catalog,
      agent_delay_ms: 0
    ] ++ extra
  end

  defp start_engine(extra \\ []) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_approval_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    start_supervised!(
      Supervisor.child_spec({Engine, engine_opts(store, extra)}, restart: :temporary)
    )

    store
  end

  defp ask_scenario(workspace) do
    Application.put_env(
      :rey_code,
      :squad_simulator,
      seed: 0,
      delay_ms: 0,
      jitter_ms: 0,
      failure_rate: 0.0,
      tool_requests: [
        %{tool: "write", arguments: %{"path" => "out.txt", "content" => "approved-content"}}
      ]
    )

    Path.join(workspace, "out.txt")
  end

  defp waiting_count(projection) do
    Enum.count(projection.invocations, fn {_id, inv} ->
      inv.status == :waiting_tool_approval
    end)
  end

  defp events_of_type(store, type) do
    EventStore.load(store) |> Enum.filter(&(&1.type == type))
  end

  defp waiting_invocations(projection, turn_id) do
    case projection.turns[turn_id] do
      nil ->
        []

      turn ->
        Enum.map(turn.invocation_order, &projection.invocations[&1])
        |> Enum.filter(&(&1 && &1.status == :waiting_tool_approval))
    end
  end

  defp resolve_all_waiting(turn_id, decision, attempts \\ 200)

  defp resolve_all_waiting(_turn_id, _decision, 0), do: flunk("turn never became terminal")

  defp resolve_all_waiting(turn_id, decision, attempts) do
    projection = Engine.snapshot(@engine)
    turn = projection.turns[turn_id]

    cond do
      turn == nil ->
        retry_resolve(turn_id, decision, attempts)

      turn.status in [:completed, :partial, :failed, :cancelled] ->
        turn

      true ->
        resolve_next_waiting(
          turn_id,
          decision,
          attempts,
          waiting_invocations(projection, turn_id)
        )
    end
  end

  defp resolve_next_waiting(turn_id, decision, attempts, [invocation | _rest]) do
    case Engine.resolve_tool_run(
           invocation.id,
           invocation.pending_tool_review.request_id,
           decision,
           @engine
         ) do
      :ok ->
        resolve_all_waiting(turn_id, decision, attempts - 1)

      {:error, reason} when reason in [:tool_review_not_pending, :invocation_not_running] ->
        retry_resolve(turn_id, decision, attempts)
    end
  end

  defp resolve_next_waiting(turn_id, decision, attempts, []),
    do: retry_resolve(turn_id, decision, attempts)

  defp retry_resolve(turn_id, decision, attempts) do
    Process.sleep(25)
    resolve_all_waiting(turn_id, decision, attempts - 1)
  end

  defp approve_until_phase(turn_id, phase, attempts \\ 200)

  defp approve_until_phase(_turn_id, phase, 0),
    do: flunk("turn never reached #{phase}")

  defp approve_until_phase(turn_id, phase, attempts) do
    projection = Engine.snapshot(@engine)
    turn = projection.turns[turn_id]

    cond do
      turn && turn.squad.phase == phase ->
        turn

      turn && turn.status in [:completed, :partial, :failed, :cancelled] ->
        turn

      waiting = List.first(waiting_invocations(projection, turn_id)) ->
        assert :ok =
                 Engine.resolve_tool_run(
                   waiting.id,
                   waiting.pending_tool_review.request_id,
                   :approve,
                   @engine
                 )

        approve_until_phase(turn_id, phase, attempts - 1)

      true ->
        Process.sleep(25)
        approve_until_phase(turn_id, phase, attempts - 1)
    end
  end

  test "approve executes the persisted request once and completes the conversation", %{
    workspace_a: workspace
  } do
    out_path = ask_scenario(workspace)
    store = start_engine()

    assert {:ok, room_id} = Engine.create_room("Approve Loop", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write it", :compare, @engine)

    turn = resolve_all_waiting(turn_id, :approve)

    assert turn.status == :completed

    assert File.read!(out_path) == "approved-content"

    started = events_of_type(store, :tool_run_started)
    completed = events_of_type(store, :tool_run_completed)

    assert length(started) == 3
    assert length(completed) == 3
    assert Enum.all?(completed, &(&1.data["result"]["ok"] == true))

    rounds = events_of_type(store, :provider_round_recorded)
    assert length(rounds) == 6

    snapshot = Engine.snapshot(@engine)

    assert Enum.all?(snapshot.turns[turn_id].invocation_order, fn id ->
             snapshot.invocations[id].status == :completed
           end)
  end

  test "a permanent squad failure cancels an approval-waiting sibling", %{
    workspace_a: workspace
  } do
    Application.put_env(
      :rey_code,
      :squad_simulator,
      seed: 0,
      delay_ms: 0,
      failure_plan: %{{"specification", "gherkin_author", 1} => :permanent},
      tool_requests: [
        %{tool: "write", arguments: %{"path" => "out.txt", "content" => "approved-content"}}
      ]
    )

    store = start_engine()
    assert {:ok, room_id} = Engine.create_room("Failed Squad Approval", workspace, @engine)

    role_ids = Enum.map(Squad.roles(), & &1.id)
    assert :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Fail safely", :squad, @engine)

    _turn = approve_until_phase(turn_id, "specification")
    turn = Wait.terminal_turn(@engine, turn_id)
    projection = Engine.snapshot(@engine)
    invocations = Enum.map(turn.invocation_order, &projection.invocations[&1])

    assert turn.status == :failed
    refute Enum.any?(invocations, &(&1.status == :waiting_tool_approval))
    assert Enum.any?(invocations, &(&1.status == :cancelled))

    assert Enum.any?(events_of_type(store, :invocation_cancelled), fn event ->
             event.data["turn_id"] == turn_id
           end)
  end

  test "deny performs no side effect and fails the invocations cleanly", %{
    workspace_a: workspace
  } do
    out_path = ask_scenario(workspace)
    store = start_engine()

    assert {:ok, room_id} = Engine.create_room("Deny Loop", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write it", :compare, @engine)

    _turn = resolve_all_waiting(turn_id, :deny)

    refute File.exists?(out_path)
    assert events_of_type(store, :tool_run_started) == []

    snapshot = Engine.snapshot(@engine)

    invocations =
      Enum.map(snapshot.turns[turn_id].invocation_order, &snapshot.invocations[&1])

    assert Enum.all?(invocations, &(&1.status == :failed))
    assert Enum.all?(invocations, &(&1.pending_tool_review == nil))
    assert Enum.all?(invocations, &(&1.error["category"] == "tool_denied"))
    assert Enum.all?(invocations, &(&1.error["retryable"] == false))

    # Denial is terminal: resolving again is rejected, and no run ever started.
    denied_invocation = snapshot.invocations[hd(snapshot.turns[turn_id].invocation_order)]

    assert {:error, :tool_review_not_pending} =
             Engine.resolve_tool_run(denied_invocation.id, "any-run", :approve, @engine)
  end

  test "approve after a complete engine restart executes exactly once", %{
    workspace_a: workspace
  } do
    out_path = ask_scenario(workspace)
    store = start_engine()

    assert {:ok, room_id} = Engine.create_room("Restart Approve", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write it", :compare, @engine)

    projection =
      Wait.projection(@engine, fn value ->
        if length(waiting_invocations(value, turn_id)) == 3, do: value
      end)

    assert length(waiting_invocations(projection, turn_id)) == 3
    assert events_of_type(store, :tool_run_started) == []

    :ok = GenServer.stop(@engine)
    assert {:ok, _restarted} = Engine.start_link(engine_opts(store))

    # Dormant after restart: still exactly three waiting approvals, nothing executed.
    restarted =
      Wait.projection(@engine, fn value ->
        if length(waiting_invocations(value, turn_id)) == 3, do: value
      end)

    assert length(waiting_invocations(restarted, turn_id)) == 3
    assert events_of_type(store, :tool_run_started) == []
    refute File.exists?(out_path)

    turn = resolve_all_waiting(turn_id, :approve)

    assert turn.status == :completed
    assert File.read!(out_path) == "approved-content"

    assert length(events_of_type(store, :tool_run_started)) == 3
    assert length(events_of_type(store, :tool_run_completed)) == 3
  end

  test "cancelling a turn cancels waiting approvals durably", %{workspace_a: workspace} do
    out_path = ask_scenario(workspace)
    store = start_engine()

    assert {:ok, room_id} = Engine.create_room("Cancel Loop", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write it", :compare, @engine)

    projection =
      Wait.projection(@engine, fn value ->
        case waiting_invocations(value, turn_id) do
          [_ | _] -> value
          [] -> nil
        end
      end)

    [waiting | _rest] = waiting_invocations(projection, turn_id)

    assert :ok = Engine.cancel_turn(turn_id, "owner changed their mind", @engine)

    snapshot = Wait.turn_status(@engine, turn_id, [:completed, :partial, :failed, :cancelled])

    assert snapshot.status == :cancelled
    refute File.exists?(out_path)
    assert events_of_type(store, :tool_run_started) == []

    invocation = Wait.projection(@engine, & &1.invocations[waiting.id])
    assert invocation.status == :cancelled
    assert invocation.pending_tool_review == nil
    assert [] == Registry.lookup(@agent_registry, waiting.id)

    assert {:error, reason} =
             Engine.resolve_tool_run(
               waiting.id,
               waiting.pending_tool_review.request_id,
               :approve,
               @engine
             )

    assert reason in [:invocation_not_running, :tool_review_not_pending]

    :ok = GenServer.stop(@engine)
    assert {:ok, _restarted} = Engine.start_link(engine_opts(store))

    assert Wait.turn_status(@engine, turn_id, [:completed, :partial, :failed, :cancelled]).status ==
             :cancelled

    refute File.exists?(out_path)
    assert events_of_type(store, :tool_run_started) == []
  end

  test "a waiting approval holds no admission slot", %{
    workspace_a: workspace_a,
    workspace_b: workspace_b
  } do
    ask_scenario(workspace_a)
    store = start_engine(global_concurrency: 1, workspace_concurrency: 1)

    assert {:ok, room_a} = Engine.create_room("Room A", workspace_a, @engine)
    assert {:ok, room_b} = Engine.create_room("Room B", workspace_b, @engine)

    assert {:ok, turn_a} = Engine.post_message(room_a, "Write it", :compare, @engine)

    Wait.projection(@engine, fn value ->
      case waiting_invocations(value, turn_a) do
        [_ | _] -> value
        [] -> nil
      end
    end)

    # Room A's three participants all wait for approval and hold no slot, so
    # Room B's invocation still starts (and reaches its own approval) under a
    # global concurrency of one.
    assert {:ok, _turn_b} = Engine.post_message(room_b, "Write it too", :compare, @engine)

    Wait.projection(@engine, fn value ->
      if waiting_count(value) == 6, do: value
    end)

    snapshot = Engine.snapshot(@engine)

    assert waiting_count(snapshot) == 6

    # The queue drains nothing while every execution is a paused approval.
    assert events_of_type(store, :tool_run_started) == []
  end
end
