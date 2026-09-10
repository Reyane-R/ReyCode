defmodule ReyCode.Orchestration.VerifiedChangeRecoveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, EventEntries, Invocation, Projector, ToolRun, Turn}

  @engine __MODULE__.Engine
  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    config =
      RuntimeConfig.fresh(
        allow_simulator_provider: true,
        default_provider: :simulator,
        provider_discovery: false
      )

    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    store = start_supervised!({EventStore, name: nil, path: Path.join(dir, "recovery.sqlite3")})

    opts = [
      name: @engine,
      event_store: store,
      agent_registry: @agent_registry,
      event_registry: @event_registry,
      agent_supervisor: @agent_supervisor,
      config: config
    ]

    start_supervised!({Engine, opts})
    {:ok, session_id} = Engine.create_blank_session("Verified", dir, @engine)
    %{store: store, opts: opts, session_id: session_id, dir: dir}
  end

  for phase <- ~w(preparing baseline implementing verifying repairing) do
    test "restart at #{phase} blocks before cancelling pending work without replay", context do
      phase = unquote(phase)
      journal(context, phase)
      before_restart = Engine.snapshot(@engine).sessions[context.session_id].verified_change
      stop_supervised!(Engine)
      append_pending_work(context)
      sequence = Projector.replay(EventStore.load(context.store)).sequence

      start_supervised!({Engine, context.opts})
      recovered = Engine.snapshot(@engine)
      record = recovered.sessions[context.session_id].verified_change
      assert record.phase == "blocked"
      assert record.error == "Interrupted during #{phase}; not resumed"
      assert %{record | phase: phase, error: nil} == before_restart
      assert_cancelled(recovered, context)

      [blocked | cancellation_events] =
        Enum.filter(EventStore.load(context.store), &(&1.sequence > sequence))

      assert blocked.type == :verified_change_recorded
      assert blocked.data["record"]["phase"] == "blocked"

      assert Enum.all?(cancellation_events, fn event ->
               event.type in [:invocation_cancelled, :turn_completed]
             end)

      assert Projector.replay(EventStore.load(context.store)) == recovered
      assert File.dir?(context.dir)
      refute File.exists?(Path.join(context.dir, "replayed"))

      assert {:error, :verified_change_terminal} =
               Engine.post_message(context.session_id, "Resume", :direct, @engine)

      assert {:terminal, :cancelled} = Engine.Client.invocation_request(@engine, "inv-pending")
      stop_supervised!(Engine)
      start_supervised!({Engine, context.opts})
      assert Engine.snapshot(@engine) == recovered
    end
  end

  for phase <- ~w(ready blocked) do
    test "#{phase} evidence survives checkpoint restart and leftover work is cancelled",
         context do
      journal(context, unquote(phase))
      before_restart = Engine.snapshot(@engine)
      assert :ok = EventStore.checkpoint(before_restart, context.store)
      stop_supervised!(Engine)
      append_pending_work(context)
      start_supervised!({Engine, context.opts})
      recovered = Engine.snapshot(@engine)

      assert recovered.sessions[context.session_id].verified_change ==
               before_restart.sessions[context.session_id].verified_change

      assert_cancelled(recovered, context)
      assert Projector.replay(EventStore.load(context.store)) == recovered

      assert {:error, :verified_change_terminal} =
               Engine.post_message(context.session_id, "More changes", :direct, @engine)

      assert {:ok, fresh_id} = Engine.create_session(context.session_id, "Fresh", @engine)
      fresh = Engine.snapshot(@engine).sessions[fresh_id]
      assert fresh.verified_change == nil
      assert fresh.participants == recovered.sessions[context.session_id].participants
    end
  end

  test "preparing with no Turns is durably blocked on restart", context do
    journal(context, "preparing")
    stop_supervised!(Engine)
    start_supervised!({Engine, context.opts})
    recovered = Engine.snapshot(@engine)
    assert recovered.sessions[context.session_id].verified_change.phase == "blocked"
    assert recovered.turns == %{}
    assert recovered == Projector.replay(EventStore.load(context.store))
  end

  test "implementing with a started tool kills the surviving worker without replay", context do
    journal(context, "implementing")
    stop_supervised!(Engine)
    append_pending_work(context)
    projection = Projector.replay(EventStore.load(context.store))
    invocation = projection.invocations["inv-pending"]
    run = invocation.tool_runs["run-pending"]

    assert {:ok, _events} =
             EventStore.append_many(
               [EventEntries.tool_run_started(invocation, run)],
               context.store
             )

    parent = self()

    {survivor, ref} =
      spawn_monitor(fn ->
        Registry.register(@agent_registry, invocation.id, nil)
        send(parent, :worker_registered)

        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    assert_receive :worker_registered, 1_000
    start_supervised!({Engine, context.opts})
    recovered = Engine.snapshot(@engine)
    assert_cancelled(recovered, context)
    assert_receive {:DOWN, ^ref, :process, ^survivor, :killed}, 1_000
    assert recovered.sessions[context.session_id].verified_change.phase == "blocked"
    refute File.exists?(Path.join(context.dir, "replayed"))
    assert recovered == Projector.replay(EventStore.load(context.store))
  end

  defp assert_cancelled(projection, context) do
    for turn_id <- ["turn-active", "turn-queued"] do
      assert projection.turns[turn_id].status == :terminal
      assert projection.turns[turn_id].outcome == :cancelled
    end

    assert projection.invocations["inv-pending"].status == :cancelled
    assert projection.invocations["inv-queued"].status == :cancelled
    assert projection.sessions[context.session_id].active_turn_id == nil
    assert projection.sessions[context.session_id].queued_turn_ids == []
    assert DynamicSupervisor.which_children(@agent_supervisor) == []
  end

  defp journal(context, target_phase) do
    check = %{
      "command" => "mix test",
      "exit_code" => 0,
      "output" => "passed",
      "error" => nil,
      "snapshot_hash" => ReyCode.Hashing.sha256_hex("base\nretained patch")
    }

    wire = %{
      "id" => "change",
      "phase" => "preparing",
      "source_workspace" => context.dir,
      "workspace" => context.dir,
      "base_commit" => "base",
      "prompt" => "Fix it",
      "commands" => ["mix test"],
      "max_repair_count" => 1,
      "repair_count" => 0,
      "timeout_ms" => 60_000,
      "check_timeout_ms" => 10_000
    }

    phases =
      case target_phase do
        "blocked" ->
          ~w(preparing blocked)

        "ready" ->
          ~w(preparing baseline implementing verifying ready)

        _phase ->
          Enum.take_while(
            ~w(preparing baseline implementing verifying repairing),
            &(&1 != target_phase)
          ) ++ [target_phase]
      end

    Enum.each(phases, fn phase ->
      evidence =
        case phase do
          "preparing" ->
            %{}

          "blocked" ->
            %{"error" => "Existing failure"}

          "repairing" ->
            %{"baseline" => [check], "repair_count" => 1}

          "ready" ->
            %{
              "baseline" => [check],
              "checks" => [check],
              "patch" => "retained patch",
              "patch_hash" => ReyCode.Hashing.sha256_hex("base\nretained patch")
            }

          _phase ->
            %{"baseline" => [check]}
        end

      assert :ok =
               Engine.record_verified_change(
                 context.session_id,
                 wire |> Map.merge(evidence) |> Map.put("phase", phase),
                 @engine
               )
    end)
  end

  defp append_pending_work(context) do
    projection = Projector.replay(EventStore.load(context.store))
    session = projection.sessions[context.session_id]
    participant = Enum.find(session.participants, &(&1.kind == :primary))
    turn = %Turn{id: "turn-active", session_id: session.id, mode: :direct, input_kind: :operator}
    queued = %{turn | id: "turn-queued", input_kind: :follow_up}

    invocation = %Invocation{
      id: "inv-pending",
      message_id: "msg-pending",
      session_id: session.id,
      turn_id: turn.id
    }

    spec = %{
      participant_id: participant.id,
      participant: participant,
      phase_index: 0,
      label: "implementation",
      system_prompt: "Implement the change",
      attempt: 1
    }

    run = %ToolRun{
      id: "run-pending",
      tool_call_id: "call-pending",
      round_index: 0,
      tool: "bash",
      arguments: %{"command" => "touch replayed"},
      workspace: context.dir,
      workspace_roots: [],
      authorization: :allow
    }

    entries =
      EventEntries.queue_turn(turn, "Implement", "msg-user", projection.sequence + 1) ++
        [EventEntries.turn_started(turn)] ++
        EventEntries.open_invocations(session, turn, [spec, spec], [
          {invocation.id, invocation.message_id},
          {"inv-queued", "msg-queued"}
        ]) ++
        [
          EventEntries.invocation_started(invocation),
          EventEntries.tool_run_requested(invocation, run)
        ] ++
        EventEntries.queue_turn(queued, "Follow up", "msg-follow-up", projection.sequence + 1)

    assert {:ok, _events} = EventStore.append_many(entries, context.store)
  end
end
