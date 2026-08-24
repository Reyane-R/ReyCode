defmodule ReyCode.AgentLoopLifecycleTest do
  @moduledoc """
  End-to-end tool-loop lifecycle contracts driven by the simulator provider.

  These tests lock the durable, provider-independent tool execution contract:
  allow-listed tools execute exactly once per recorded run, ask tools pause
  durably without executing, waiting approvals release the worker and survive
  engine restarts, provider frames never overwrite approval state, and
  multi-round conversations retain every round.
  """

  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, ToolRun}
  alias ReyCode.Provider.Frame
  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tool_loop_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "hello.txt"), "tool-loop-content")

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{workspace: workspace}
  end

  defp engine_opts(store, simulator_opts) do
    [
      name: @engine,
      event_store: store,
      agent_supervisor: @agent_supervisor,
      agent_registry: @agent_registry,
      event_registry: @event_registry,
      provider_catalog: ReyCode.Provider.Catalog,
      config:
        RuntimeConfig.fresh(
          allow_simulator_provider: true,
          default_provider: :simulator
        ),
      agent_delay_ms: 0,
      simulator_opts:
        Keyword.merge(
          [seed: 0, delay_ms: 0, jitter_ms: 0, failure_rate: 0.0],
          simulator_opts
        )
    ]
  end

  defp start_engine(_workspace, simulator_opts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tool_loop_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    start_supervised!(
      Supervisor.child_spec({Engine, engine_opts(store, simulator_opts)}, restart: :temporary)
    )

    %{store: store}
  end

  defp tool_write_pause do
    [tool_requests: [%{tool: "write", arguments: %{"path" => "out.txt", "content" => "paused"}}]]
  end

  defp events_of_type(store, type) do
    EventStore.load(store) |> Enum.filter(&(&1.type == type))
  end

  defp per_invocation(events) do
    events
    |> Enum.group_by(& &1.data["invocation_id"])
    |> Map.delete(nil)
  end

  defp wait_until_gone(registry, key, attempts \\ 100)
  defp wait_until_gone(_registry, _key, 0), do: flunk("registry entry never cleared")

  defp wait_until_gone(registry, key, attempts) do
    if Registry.lookup(registry, key) == [] do
      :ok
    else
      Process.sleep(20)
      wait_until_gone(registry, key, attempts - 1)
    end
  end

  defp waiting_invocation(projection, turn_id) do
    Enum.find_value(projection.turns[turn_id].invocation_order, fn id ->
      inv = projection.invocations[id]
      inv && inv.status == :waiting_tool_approval && inv
    end)
  end

  test "allow-listed tool executes once and its result reaches the next round", %{
    workspace: workspace
  } do
    %{store: store} =
      start_engine(workspace,
        tool_requests: [%{tool: "read", arguments: %{"path" => "hello.txt"}}]
      )

    assert {:ok, room_id} = Engine.create_room("Tool Loop", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Read the file", :compare, @engine)

    assert Wait.terminal_turn(@engine, turn_id).status == :completed

    rounds = per_invocation(events_of_type(store, :provider_round_recorded))

    assert map_size(rounds) == 3

    Enum.each(rounds, fn {_invocation_id, invocation_rounds} ->
      assert length(invocation_rounds) == 2

      assert hd(invocation_rounds).data["tool_calls"] == [
               %{
                 "id" => "simulated-tool-1",
                 "tool" => "read",
                 "arguments" => %{"path" => "hello.txt"}
               }
             ]

      assert List.last(invocation_rounds).data["tool_calls"] == []
    end)

    requested = events_of_type(store, :tool_run_requested)
    started = events_of_type(store, :tool_run_started)
    completed = events_of_type(store, :tool_run_completed)

    assert length(requested) == 3
    assert Enum.all?(requested, &(&1.data["authorization"] == "allow"))
    assert Enum.all?(requested, &(&1.data["tool"] == "read"))

    assert length(started) == 3
    assert length(completed) == 3
    assert Enum.all?(completed, &(&1.data["result"]["ok"] == true))
    assert Enum.all?(completed, &(&1.data["result"]["output"] =~ "tool-loop-content"))

    snapshot = Engine.snapshot(@engine)

    invocation_id = hd(snapshot.turns[turn_id].invocation_order)
    message = snapshot.messages[snapshot.invocations[invocation_id].message_id]
    assert message.status == :completed
    assert message.body =~ "tool results"
  end

  test "tool failures are durable results and the provider can recover", %{workspace: workspace} do
    %{store: store} =
      start_engine(workspace,
        tool_requests: [%{tool: "read", arguments: %{"path" => "missing.txt"}}]
      )

    assert {:ok, room_id} = Engine.create_room("Tool Failure", workspace, @engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Read the missing file", :compare, @engine)

    assert Wait.terminal_turn(@engine, turn_id).status == :completed

    started = events_of_type(store, :tool_run_started)
    failed = events_of_type(store, :tool_run_failed)

    assert length(started) == 3
    assert length(failed) == 3
    assert events_of_type(store, :tool_run_completed) == []

    assert Enum.all?(failed, fn event ->
             event.data["error"] == %{
               "ok" => false,
               "output" => nil,
               "error" => "enoent",
               "truncated" => false,
               "metadata" => %{}
             } and
               event.data["result"] == event.data["error"]
           end)

    snapshot = Engine.snapshot(@engine)

    assert Enum.all?(snapshot.turns[turn_id].invocation_order, fn invocation_id ->
             invocation = snapshot.invocations[invocation_id]
             run = invocation.tool_runs[hd(invocation.tool_run_order)]
             invocation.status == :completed and run.status == :failed
           end)
  end

  test "ask tool pauses durably without executing and releases the worker", %{
    workspace: workspace
  } do
    %{store: store} = start_engine(workspace, tool_write_pause())

    assert {:ok, room_id} = Engine.create_room("Ask Loop", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write the file", :compare, @engine)

    invocation =
      Wait.projection(@engine, fn projection ->
        waiting_invocation(projection, turn_id)
      end)

    assert invocation.pending_tool_review.tool == "write"

    assert :ok = wait_until_gone(@agent_registry, invocation.id)

    assert events_of_type(store, :tool_run_started) == []
    refute File.exists?(Path.join(workspace, "out.txt"))

    run = invocation.tool_runs[hd(invocation.tool_run_order)]
    assert %ToolRun{} = run
    assert run.status == :awaiting_approval
    assert run.tool == "write"
    assert run.arguments == %{"path" => "out.txt", "content" => "paused"}
  end

  test "provider frames never overwrite waiting approval status", %{workspace: workspace} do
    %{store: store} = start_engine(workspace, tool_write_pause())

    assert {:ok, room_id} = Engine.create_room("Frame Guard", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write the file", :compare, @engine)

    projection =
      Wait.projection(@engine, fn projection ->
        waiting_invocation(projection, turn_id) && projection
      end)

    invocation_id = waiting_invocation(projection, turn_id).id

    sequence = projection.invocations[invocation_id].last_frame_sequence + 1

    assert :ok =
             Engine.Client.record_frame(
               @engine,
               invocation_id,
               Frame.text_delta(sequence, " stray frame ")
             )

    assert Wait.projection(@engine, fn next ->
             inv = next.invocations[invocation_id]
             inv && inv.status == :waiting_tool_approval && inv.pending_tool_review && next
           end)

    assert events_of_type(store, :tool_run_started) == []
  end

  test "waiting approval survives engine restart and stays dormant", %{workspace: workspace} do
    %{store: store} = start_engine(workspace, tool_write_pause())

    assert {:ok, room_id} = Engine.create_room("Restart Loop", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Write the file", :compare, @engine)

    projection =
      Wait.projection(@engine, fn projection ->
        waiting_invocation(projection, turn_id) && projection
      end)

    invocation = waiting_invocation(projection, turn_id)

    :ok = GenServer.stop(@engine)

    assert {:ok, _restarted} = Engine.start_link(engine_opts(store, tool_write_pause()))

    assert Wait.projection(@engine, fn next ->
             inv = next.invocations[invocation.id]
             inv && inv.status == :waiting_tool_approval && inv.pending_tool_review && next
           end)

    assert [] == Registry.lookup(@agent_registry, invocation.id)
    assert events_of_type(store, :tool_run_started) == []
    refute File.exists?(Path.join(workspace, "out.txt"))
  end

  test "sequential tool rounds keep the full conversation", %{workspace: workspace} do
    %{store: store} =
      start_engine(workspace,
        tool_requests: [
          %{tool: "read", arguments: %{"path" => "hello.txt"}},
          %{tool: "list", arguments: %{"path" => "."}}
        ]
      )

    assert {:ok, room_id} = Engine.create_room("Multi Round", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Inspect twice", :compare, @engine)

    assert Wait.terminal_turn(@engine, turn_id).status == :completed

    rounds = per_invocation(events_of_type(store, :provider_round_recorded))

    assert map_size(rounds) == 3

    Enum.each(rounds, fn {_invocation_id, invocation_rounds} ->
      tool_rounds =
        Enum.filter(invocation_rounds, &(&1.data["tool_calls"] != []))

      assert length(tool_rounds) == 2

      assert Enum.map(tool_rounds, &hd(&1.data["tool_calls"])["tool"]) == ["read", "list"]

      final_round = List.last(invocation_rounds)
      assert final_round.data["tool_calls"] == []
    end)

    started = events_of_type(store, :tool_run_started)
    completed = events_of_type(store, :tool_run_completed)

    assert length(started) == 6
    assert length(completed) == 6
    assert Enum.all?(completed, &(&1.data["result"]["ok"] == true))

    snapshot = Engine.snapshot(@engine)

    invocation_id = hd(snapshot.turns[turn_id].invocation_order)
    message = snapshot.messages[snapshot.invocations[invocation_id].message_id]
    assert message.body =~ "after 2 tool results"
  end
end
