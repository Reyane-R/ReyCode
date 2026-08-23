defmodule ReyCode.Orchestration.AdmissionTest do
  use ExUnit.Case, async: true

  alias ReyCode.EventStore
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_admission_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    %{store: store}
  end

  test "serializes provider workers under global and workspace limits", %{store: store} do
    start_engine(store, global_concurrency: 1, workspace_concurrency: 1)
    room_id = Engine.snapshot(@engine).room_order |> hd()
    assert {:ok, turn_id} = Engine.post_message(room_id, "Bound this work", :compare, @engine)

    Wait.projection(@engine, fn projection ->
      turn = projection.turns[turn_id]
      statuses = turn && Enum.map(turn.invocation_order, &projection.invocations[&1].status)

      if Enum.count(statuses || [], &(&1 == :running)) == 1 and
           Enum.count(statuses || [], &(&1 == :queued)) == 2,
         do: projection
    end)

    assert Wait.terminal_turn(@engine, turn_id).status == :completed
  end

  test "rejects queued turns when the configured global queue is full", %{store: store} do
    start_engine(store,
      global_concurrency: 1,
      workspace_concurrency: 1,
      global_queue_limit: 0,
      workspace_queue_limit: 0
    )

    room_id = Engine.snapshot(@engine).room_order |> hd()
    assert {:ok, turn_id} = Engine.post_message(room_id, "Occupy capacity", :compare, @engine)
    assert Wait.turn_status(@engine, turn_id, :running).status == :running

    assert {:error, :global_queue_full} =
             Engine.post_message(room_id, "Do not enqueue", :compare, @engine)

    assert Wait.terminal_turn(@engine, turn_id).status == :completed
  end

  test "durably cancels running and queued invocations without retries", %{store: store} do
    start_engine(store, global_concurrency: 1, workspace_concurrency: 1)
    room_id = Engine.snapshot(@engine).room_order |> hd()
    assert {:ok, turn_id} = Engine.post_message(room_id, "Cancel this work", :compare, @engine)
    running_id = Wait.invocation_status(@engine, turn_id, :running).id

    {worker, _value} = Wait.registry_entry(@agent_registry, running_id)
    worker_ref = Process.monitor(worker)

    assert :ok = Engine.cancel_turn(turn_id, "User stopped the turn", @engine)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000

    projection = Engine.snapshot(@engine)
    turn = projection.turns[turn_id]
    assert turn.status == :cancelled
    assert turn.outcome == :cancelled
    assert Enum.all?(turn.invocation_order, &(projection.invocations[&1].status == :cancelled))
    assert EventStore.load(store) |> Enum.any?(&(&1.type == :invocation_cancelled))
    assert Registry.lookup(@agent_registry, running_id) == []
  end

  defp start_engine(store, limits) do
    start_supervised!(
      {Engine,
       [
         name: @engine,
         event_store: store,
         agent_supervisor: @agent_supervisor,
         agent_registry: @agent_registry,
         event_registry: @event_registry,
         provider_catalog: ReyCode.Provider.Catalog,
         agent_delay_ms: 100
       ] ++ limits}
    )
  end
end
