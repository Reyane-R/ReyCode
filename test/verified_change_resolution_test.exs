defmodule ReyCode.VerifiedChangeResolutionTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, Hashing, RuntimeConfig}
  alias ReyCode.EventStore.SQLite.Checkpoint
  alias ReyCode.Orchestration.{DelegationWorktree, Engine, Projector, Session, VerifiedChange}
  alias ReyCode.Orchestration.Engine.{Persistence, SourceTask}
  alias ReyCode.Orchestration.Engine.VerifiedChangeResolution, as: Handlers
  alias ReyCode.Orchestration.VerifiedChangeResolution, as: Resolution
  alias ReyCode.Security.CanonicalPath
  alias ReyCode.Test.Wait
  alias ReyCode.VerifiedChange.{Patch, Worktree}

  @moduletag :tmp_dir
  @event_registry __MODULE__.EventRegistry

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    File.mkdir!(source)
    {:ok, source} = CanonicalPath.resolve(source)
    git!(source, ["init", "-q"])
    File.write!(Path.join(source, "value.txt"), "before\n")
    git!(source, ["add", "."])
    commit!(source)
    base = String.trim(git!(source, ["rev-parse", "HEAD"]))
    File.write!(Path.join(source, "value.txt"), "after\n")
    {:ok, patch, hash} = Worktree.snapshot(source, base, deadline())
    File.write!(Path.join(source, "value.txt"), "before\n")

    check = %{
      "command" => "true",
      "exit_code" => 0,
      "output" => "",
      "error" => nil,
      "snapshot_hash" => hash
    }

    change = %VerifiedChange{
      id: "change",
      phase: "ready",
      source_workspace: source,
      workspace: Path.join(dir, "deleted-candidate"),
      base_commit: base,
      prompt: "Fix value",
      commands: ["true"],
      max_repair_count: 0,
      repair_count: 0,
      timeout_ms: 60_000,
      check_timeout_ms: 1000,
      baseline: [check],
      checks: [check],
      patch: patch,
      patch_hash: hash,
      error: nil
    }

    {:ok, ^change} = change |> VerifiedChange.to_wire() |> VerifiedChange.from_wire()
    %{change: change, source: source, dir: dir}
  end

  test "applies retained bytes with no candidate and reconciles the whole source", %{
    change: change,
    source: source
  } do
    refute File.exists?(change.workspace)
    assert {:applied, nil} = Patch.execute(change, :apply)
    assert File.read!(Path.join(source, "value.txt")) == "after\n"
    assert git!(source, ["diff", "--cached"]) == ""
    assert {:applied, nil} = Patch.reconcile(change, :apply)
    assert {:failed, _} = Patch.execute(change, :apply)

    File.write!(Path.join(source, "unrelated.txt"), "external writer\n")
    assert {:indeterminate, _} = Patch.reconcile(change, :apply)
    assert File.read!(Path.join(source, "unrelated.txt")) == "external writer\n"
  end

  test "candidate edits cannot replace retained patch bytes", %{change: change, source: source} do
    File.mkdir!(change.workspace)
    File.write!(Path.join(change.workspace, "value.txt"), "unverified\n")
    assert {:applied, nil} = Patch.execute(change, :apply)
    assert File.read!(Path.join(source, "value.txt")) == "after\n"
  end

  test "dirty index, untracked files, hidden modifications and advanced HEAD fail closed", %{
    change: change,
    source: source
  } do
    path = Path.join(source, "value.txt")
    File.write!(path, "dirty\n")
    git!(source, ["update-index", "--assume-unchanged", "value.txt"])
    assert {:failed, _} = Patch.execute(change, :apply)
    assert File.read!(path) == "dirty\n"
    git!(source, ["update-index", "--no-assume-unchanged", "value.txt"])
    File.write!(path, "before\n")
    File.write!(Path.join(source, "extra"), "dirty")
    assert {:failed, _} = Patch.execute(change, :apply)
    File.rm!(Path.join(source, "extra"))
    File.write!(path, "staged\n")
    git!(source, ["add", "."])
    File.write!(path, "before\n")
    assert {:failed, _} = Patch.execute(change, :apply)
    assert {:indeterminate, _} = Patch.reconcile(change, :apply)
    commit!(source)
    assert {:failed, _} = Patch.execute(change, :apply)
    assert {:indeterminate, _} = Patch.reconcile(change, :apply)
  end

  test "corrupt hash and blocked Apply cannot mutate; Discard never deletes paths", %{
    change: change,
    source: source
  } do
    assert {:failed, _} = Patch.execute(%{change | patch_hash: "wrong"}, :apply)
    assert {:failed, _} = Patch.execute(%{change | phase: "blocked"}, :apply)

    assert {:discarded, nil} =
             Patch.execute(%{change | phase: "blocked", workspace: source}, :discard)

    assert File.read!(Path.join(source, "value.txt")) == "before\n"
    assert {:failed, "source_at_pristine_base"} = Patch.reconcile(change, :apply)
  end

  test "binary additions, deletion, executable mode and symlinks apply exactly", %{
    change: change,
    source: source
  } do
    File.rm!(Path.join(source, "value.txt"))
    File.write!(Path.join(source, "binary"), <<0, 1, 255, 2>>)
    File.write!(Path.join(source, "executable"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(source, "executable"), 0o755)
    File.ln_s!("binary", Path.join(source, "link"))
    {:ok, patch, hash} = Worktree.snapshot(source, change.base_commit, deadline())
    for path <- ["binary", "executable", "link"], do: File.rm!(Path.join(source, path))
    File.write!(Path.join(source, "value.txt"), "before\n")
    change = %{change | patch: patch, patch_hash: hash}
    assert {:applied, nil} = Patch.execute(change, :apply)
    assert File.read!(Path.join(source, "binary")) == <<0, 1, 255, 2>>
    assert File.read_link!(Path.join(source, "link")) == "binary"
    refute File.exists?(Path.join(source, "value.txt"))
    assert {:applied, nil} = Patch.reconcile(change, :apply)
  end

  test "resolution wire is closed, typed, bounded, and decision-consistent", %{change: change} do
    record = requested(change)
    wire = Resolution.to_wire(record)
    assert {:ok, ^record} = Resolution.from_wire(wire)
    assert Resolution.from_map(Map.from_struct(record)) == record
    assert Session.from_map(%{id: "legacy"}).verified_change_resolution == nil

    for {field, value} <- [
          {"id", ""},
          {"change_id", nil},
          {"patch_hash", 7},
          {"decision", "approve"},
          {"status", "applying"},
          {"error", "unexpected"},
          {"unknown", 1}
        ] do
      assert {:error, _} = Resolution.from_wire(Map.put(wire, field, value))
    end

    assert {:error, _} = Resolution.from_wire(nil)
    assert {:error, _} = Resolution.from_wire(Map.delete(wire, "error"))

    assert {:error, _} =
             Resolution.from_wire(%{
               wire
               | "status" => "failed",
                 "error" => String.duplicate("x", 4001)
             })

    assert {:error, _} = Resolution.from_wire(%{wire | "status" => "discarded"})
    assert :ok = Resolution.transition(nil, record)
    assert {:error, _} = Resolution.transition(record, record)
    applied = %{record | status: :applied}
    assert :ok = Resolution.transition(record, applied)
    assert {:error, _} = Resolution.transition(applied, record)
    assert {:error, _} = Resolution.transition(record, %{applied | id: "different"})
    refute Resolution.bound?(%{record | change_id: "stale"}, change)
    refute Resolution.bound?(record, %{change | phase: "blocked"})
    assert Resolution.bound?(%{record | decision: :discard}, %{change | phase: "blocked"})
  end

  test "durable async intent, duplicate rejection, completion, replay and checkpoint", context do
    state = state(context)
    change = context.change

    assert {:reply, {:ok, id}, requested_state} =
             Handlers.resolve(state, "session", change.id, change.patch_hash, :apply)

    assert resolution(requested_state).status == :requested
    assert resolution(requested_state).id == id
    assert Handlers.locked_workspace?(requested_state.projection, context.source)

    assert Handlers.locked_workspace?(
             requested_state.projection,
             Path.join(context.source, "nested")
           )

    refute Handlers.locked_workspace?(requested_state.projection, context.source <> "-other")

    assert {:reply, {:error, :verified_change_already_resolved}, ^requested_state} =
             Handlers.resolve(requested_state, "session", change.id, change.patch_hash, :discard)

    assert List.last(EventStore.load(state.event_store)).data["record"]["status"] == "requested"
    finished = finish(requested_state)
    assert resolution(finished).status == :applied
    assert finished.projection.sessions["session"].verified_change == change
    refute Handlers.locked_workspace?(finished.projection, context.source)
    assert Projector.replay(EventStore.load(state.event_store)) == finished.projection
    assert :ok = EventStore.checkpoint(finished.projection, state.event_store)
    assert Persistence.restore!(state.event_store) == finished.projection
    assert {:noreply, ^finished} = Handlers.down(finished, make_ref(), :late)
  end

  test "stale, blocked, busy and capacity requests reject before intent", context do
    state = state(context)
    change = context.change

    for {id, hash, decision} <- [
          {"stale", change.patch_hash, :apply},
          {change.id, "wrong", :apply},
          {change.id, change.patch_hash, :approve}
        ] do
      assert {:reply, {:error, _}, ^state} =
               Handlers.resolve(state, "session", id, hash, decision)
    end

    assert {:reply, {:error, :session_not_found}, ^state} =
             Handlers.resolve(state, "absent", change.id, change.patch_hash, :apply)

    busy = put_in(state.projection.sessions["session"].active_turn_id, "turn")

    assert {:reply, {:error, :verified_change_busy}, ^busy} =
             Handlers.resolve(busy, "session", change.id, change.patch_hash, :apply)

    full = %{
      state
      | verified_change_resolution_tasks: Map.new(1..4, &{&1, {"other", "id", self()}})
    }

    assert {:reply, {:error, :resolution_capacity_exceeded}, ^full} =
             Handlers.resolve(full, "session", change.id, change.patch_hash, :apply)
  end

  test "worker loss and restart never replay Apply; explicit reconcile alone settles", context do
    state = state(context)
    record = requested(context.change)
    state = Persistence.append_and_apply!(state, [entry(record)])
    ref = make_ref()

    running = %{
      state
      | verified_change_resolution_tasks: %{ref => {"session", record.id, self()}}
    }

    assert {:noreply, uncertain} = Handlers.down(running, ref, :killed)
    assert resolution(uncertain).status == :indeterminate
    assert Handlers.locked_workspace?(uncertain.projection, context.source)
    assert {:failed, "source_at_pristine_base"} = Patch.reconcile(context.change, :apply)
    assert :ok = EventStore.checkpoint(uncertain.projection, state.event_store)
    restored = %{uncertain | projection: Persistence.restore!(state.event_store)}
    assert Handlers.recover(restored) == restored

    assert {:reply, {:ok, _}, reconciling} =
             Handlers.reconcile(restored, "session", context.change.id, context.change.patch_hash)

    assert {:reply, {:error, :resolution_not_reconcilable}, ^reconciling} =
             Handlers.reconcile(
               reconciling,
               "session",
               context.change.id,
               context.change.patch_hash
             )

    settled = finish(reconciling)
    assert resolution(settled).status == :failed
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
  end

  test "restart after mutation before completion records uncertainty then recognizes exact applied snapshot",
       context do
    state = state(context)
    state = Persistence.append_and_apply!(state, [entry(requested(context.change))])
    assert {:applied, nil} = Patch.execute(context.change, :apply)
    restored = %{state | projection: Persistence.restore!(state.event_store)}
    recovered = Handlers.recover(restored)
    assert resolution(recovered).status == :indeterminate
    assert resolution(recovered).id == resolution(state).id
    assert Handlers.recover(recovered) == recovered

    assert {:reply, {:ok, _}, reconciling} =
             Handlers.reconcile(
               recovered,
               "session",
               context.change.id,
               context.change.patch_hash
             )

    assert resolution(finish(reconciling)).status == :applied
  end

  test "blocked Discard preserves evidence and existing workspace", context do
    blocked = %{
      context.change
      | phase: "blocked",
        patch_hash: nil,
        error: "checks failed",
        workspace: context.source
    }

    state = state(%{context | change: blocked})

    assert {:reply, {:error, :stale_or_ineligible_verified_change}, ^state} =
             Handlers.resolve(state, "session", blocked.id, nil, :apply)

    assert {:reply, {:ok, _}, pending} =
             Handlers.resolve(state, "session", blocked.id, nil, :discard)

    finished = finish(pending)
    assert resolution(finished).status == :discarded
    assert finished.projection.sessions["session"].verified_change == blocked
    assert File.dir?(context.source)
  end

  test "checkpoint rejects malformed or misbound resolution and retains legacy absence",
       context do
    state = state(context)

    projection =
      put_in(
        state.projection,
        [Access.key(:sessions), "session", Access.key(:verified_change_resolution)],
        requested(context.change)
      )

    assert {:ok, _} = decode(projection)
    invalid = put_in(projection.sessions["session"].verified_change_resolution.change_id, "other")
    assert {:error, :invalid_checkpoint} = decode(invalid)
    invalid = put_in(projection.sessions["session"].verified_change_resolution.status, :unknown)
    assert {:error, :invalid_checkpoint} = decode(invalid)

    legacy =
      put_in(
        projection.sessions["session"],
        Map.delete(Map.from_struct(projection.sessions["session"]), :verified_change_resolution)
      )

    assert {:ok, _} = decode(legacy)
  end

  test "failed durable intent cannot dispatch mutation", context do
    state = state(context)

    assert {:ok, _} =
             EventStore.append_many([entry(requested(context.change))], state.event_store)

    assert_raise Persistence.DurableAppendError, fn ->
      Handlers.resolve(state, "session", context.change.id, context.change.patch_hash, :apply)
    end

    assert Task.Supervisor.children(state.task_supervisor) == []
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
  end

  test "dispatch failure is durable uncertainty and retains the source barrier", context do
    state = %{state(context) | task_supervisor: __MODULE__.MissingSupervisor}

    assert {:reply, {:ok, _}, uncertain} =
             Handlers.resolve(
               state,
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply
             )

    assert resolution(uncertain).status == :indeterminate
    assert resolution(uncertain).error == "resolution_dispatch_failed"
    assert Handlers.locked_workspace?(uncertain.projection, context.source)
    assert Projector.replay(EventStore.load(state.event_store)) == uncertain.projection
  end

  test "store stop and reopen preserves requested intent without replaying mutation", context do
    state = state(context)
    state = Persistence.append_and_apply!(state, [entry(requested(context.change))])
    assert :ok = EventStore.checkpoint(state.projection, state.event_store)
    stop_supervised!(EventStore)

    store =
      start_supervised!(
        {EventStore, name: nil, path: Path.join(context.dir, "resolution.sqlite3")}
      )

    restored = %{state | event_store: store, projection: Persistence.restore!(store)}
    recovered = Handlers.recover(restored)
    assert resolution(recovered).status == :indeterminate
    assert resolution(recovered).id == resolution(state).id
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
    assert Projector.replay(EventStore.load(store)) == recovered.projection
  end

  test "Engine APIs apply a deleted candidate and reject duplicate identity", context do
    state = state(context)
    {engine, _opts} = engine(state)
    change = context.change

    assert {:error, :stale_or_ineligible_verified_change} =
             Engine.resolve_verified_change("session", change.id, "stale", :apply, engine)

    assert {:ok, id} =
             Engine.resolve_verified_change(
               "session",
               change.id,
               change.patch_hash,
               :apply,
               engine
             )

    assert is_binary(id)

    assert {:error, :verified_change_already_resolved} =
             Engine.resolve_verified_change(
               "session",
               change.id,
               change.patch_hash,
               :discard,
               engine
             )

    assert Wait.projection(
             engine,
             fn projection ->
               projection.sessions["session"].verified_change_resolution.status == :applied
             end,
             10_000
           )

    assert Engine.snapshot(engine).sessions["session"].verified_change == change
    assert File.read!(Path.join(context.source, "value.txt")) == "after\n"

    assert {:error, :resolution_not_reconcilable} =
             Engine.reconcile_verified_change("session", change.id, change.patch_hash, engine)
  end

  test "Engine recovery locks all new work until explicit reconciliation", context do
    state = state(context)
    {engine, opts} = engine(state)
    {:ok, ordinary} = Engine.create_blank_session("Ordinary", context.source, engine)
    {:ok, participant} = Engine.add_task_participant(ordinary, "Worker", "Test", engine)
    stop_supervised!(Engine)
    {:ok, _} = EventStore.append_many([entry(requested(context.change))], state.event_store)
    engine = start_supervised!({Engine, opts})

    assert Engine.snapshot(engine).sessions["session"].verified_change_resolution.status ==
             :indeterminate

    assert {:error, :verified_change_source_locked} =
             Engine.post_message(ordinary, "No mutation", :direct, engine)

    assert {:error, :verified_change_source_locked} =
             Engine.delegate_task(ordinary, participant, "No mutation", engine)

    assert {:error, :verified_change_source_locked} =
             Engine.run_owner_command(ordinary, "touch forbidden", engine)

    assert {:error, :verified_change_source_locked} =
             Engine.start_verified_change(
               ordinary,
               %{
                 prompt: "New",
                 commands: ["true"],
                 max_repair_count: 0,
                 timeout_ms: 60_000,
                 check_timeout_ms: 1000
               },
               engine
             )

    assert {:ok, "resolution"} =
             Engine.reconcile_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               engine
             )

    assert Wait.projection(
             engine,
             fn projection ->
               projection.sessions["session"].verified_change_resolution.status == :failed
             end,
             10_000
           )

    assert :ok = Engine.run_owner_command(ordinary, "printf allowed", engine)
    refute File.exists?(Path.join(context.source, "forbidden"))
  end

  @tag tools: [%{tool: "bash", arguments: %{"command" => "printf approved"}}]
  test "queued and approval-paused ordinary Turns prevent resolution globally", context do
    state = state(context)
    {engine, _opts} = engine(state, tool_requests: context.tools)
    {:ok, ordinary} = Engine.create_blank_session("Ordinary", context.source, engine)
    {:ok, turn_id} = Engine.post_message(ordinary, "Pause for approval", :direct, engine)

    assert Wait.projection(
             engine,
             fn projection ->
               Enum.any?(projection.invocations, fn {_id, invocation} ->
                 invocation.status == :waiting_tool_approval
               end)
             end,
             10_000
           )

    {:ok, queued} = Engine.post_message(ordinary, "Queued", :direct, engine)
    assert Engine.snapshot(engine).turns[queued].status == :queued

    assert {:error, :verified_change_busy} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    assert :ok = Engine.cancel_turn(queued, "test", engine)

    assert {:error, :verified_change_busy} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    assert :ok = Engine.cancel_turn(turn_id, "test", engine)
    assert wait_until(fn -> map_size(:sys.get_state(engine).active_executions) == 0 end, 10_000)

    assert {:ok, _} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :discard,
               engine
             )
  end

  test "old Engine owner command keeps its draining lease across restart", context do
    state = state(context)
    {engine, opts} = engine(state)
    {:ok, ordinary} = Engine.create_blank_session("Ordinary", context.source, engine)
    marker = Path.join(context.dir, "owner-started")
    release = Path.join(context.dir, "owner-release")
    command = "printf started > '#{marker}'; while [ ! -f '#{release}' ]; do sleep 0.01; done"
    assert :ok = Engine.run_owner_command(ordinary, command, engine)
    assert wait_until(fn -> File.exists?(marker) end, 5_000)

    assert {:error, :verified_change_busy} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    stop_supervised!(Engine)
    {:ok, _} = EventStore.append_many([entry(requested(context.change))], state.event_store)
    engine = start_supervised!({Engine, opts})

    assert {:error, :verified_change_busy} =
             Engine.reconcile_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               engine
             )

    File.write!(release, "go")
    assert wait_until(fn -> not SourceTask.busy?(state) end, 10_000)

    assert {:ok, _} =
             Engine.reconcile_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               engine
             )

    assert Wait.projection(
             engine,
             fn projection ->
               projection.sessions["session"].verified_change_resolution.status == :failed
             end,
             10_000
           )
  end

  test "ordinary provider Bash keeps Apply blocked after Engine recovery terminalizes its invocation",
       context do
    state = state(context)
    marker = Path.join(context.dir, "provider-started")
    gate = Path.join(context.dir, "provider-release")
    finished = Path.join(context.dir, "provider-finished")

    command =
      "printf started >> '#{marker}'; while ! test -f '#{gate}'; do sleep 0.01; done; printf drained > '#{finished}'"

    tools = [%{tool: "bash", arguments: %{"command" => command}}]
    {engine, opts} = engine(state, tool_requests: tools)
    {:ok, ordinary} = Engine.create_blank_session("Ordinary", context.source, engine)
    {:ok, turn_id} = Engine.post_message(ordinary, "Run approved shell", :direct, engine)
    invocation = Wait.invocation_status(engine, turn_id, :waiting_tool_approval)
    run = invocation.tool_runs |> Map.values() |> Enum.find(&(&1.status == :awaiting_approval))
    assert :ok = Engine.resolve_tool_run(invocation.id, run.id, :approve, engine)
    assert wait_until(fn -> File.exists?(marker) end, 5_000)
    assert SourceTask.busy?(state)
    stop_supervised!(Engine)
    engine = start_supervised!({Engine, opts})

    assert Wait.projection(
             engine,
             fn projection -> projection.invocations[invocation.id].status == :failed end,
             10_000
           )

    assert :sys.get_state(engine).active_executions == %{}

    assert {:error, :verified_change_busy} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    refute File.exists?(finished)
    File.write!(gate, "release")
    assert wait_until(fn -> not SourceTask.busy?(state) end, 10_000)
    assert File.read!(finished) == "drained"
    assert File.read!(marker) == "started"

    assert {:ok, _} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    assert Wait.projection(
             engine,
             fn projection ->
               projection.sessions["session"].verified_change_resolution.status == :applied
             end,
             10_000
           )
  end

  test "killed verification coordinator stays stopping and blocks Apply and competing owners until check drain",
       context do
    state = state(context)
    {engine, _opts} = engine(state)
    {:ok, ordinary} = Engine.create_blank_session("Source", context.source, engine)
    marker = Path.join(context.dir, "verification-started")
    gate = Path.join(context.dir, "verification-release")
    finished = Path.join(context.dir, "verification-finished")

    command =
      "printf started >> '#{marker}'; while ! test -f '#{gate}'; do sleep 0.01; done; printf drained > '#{finished}'"

    options = %{
      prompt: "Run checks",
      commands: [command],
      timeout_ms: 60_000,
      check_timeout_ms: 30_000,
      max_repair_count: 0
    }

    {:ok, session_id} = Engine.start_verified_change(ordinary, options, engine)
    assert wait_until(fn -> File.exists?(marker) end, 10_000)
    coordinator = :sys.get_state(engine).verified_changes[session_id].pid
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}, 5_000

    assert Wait.projection(
             engine,
             fn projection ->
               projection.sessions[session_id].verified_change.phase == "blocked"
             end,
             10_000
           )

    assert wait_until(
             fn -> not Map.has_key?(:sys.get_state(engine).verified_changes, session_id) end,
             5_000
           )

    assert Engine.verified_change_status(session_id, engine) == :stopping

    assert {:error, :verified_change_busy} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    assert {:error, :verified_change_stopping} =
             Engine.start_verified_change(ordinary, options, engine)

    assert {:error, :source_operation_not_owner} =
             SourceTask.run(
               engine,
               {:verification, session_id},
               fn -> flunk("cancelled verification started another operation") end,
               1_000
             )

    refute File.exists?(finished)
    File.write!(gate, "release")

    assert wait_until(
             fn -> Engine.verified_change_status(session_id, engine) == :stopped end,
             10_000
           )

    assert File.read!(finished) == "drained"
    assert File.read!(marker) == "started"

    assert {:ok, _} =
             Engine.resolve_verified_change(
               "session",
               context.change.id,
               context.change.patch_hash,
               :apply,
               engine
             )

    assert Wait.projection(
             engine,
             fn projection ->
               projection.sessions["session"].verified_change_resolution.status == :applied
             end,
             10_000
           )

    retained = Engine.snapshot(engine).sessions[session_id].verified_change

    assert :ok =
             DelegationWorktree.cleanup(%{
               source_workspace: context.source,
               workspace: retained.workspace
             })
  end

  test "source task owner loss drains and cannot authorize later Apply", context do
    state = state(context)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _task} =
          SourceTask.start(state, fn engine ->
            send(parent, {:source_lease, self()})

            receive do
              :continue -> Patch.execute(context.change, :apply, engine)
            after
              10_000 -> {:failed, "test_deadline"}
            end
          end)

        receive do
          :stop -> :ok
        after
          10_000 -> :ok
        end
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:source_lease, worker}, 5_000
    worker_ref = Process.monitor(worker)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
    assert SourceTask.busy?(state)
    send(worker, :continue)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 10_000
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
    assert wait_until(fn -> not SourceTask.busy?(state) end, 5_000)
  end

  test "lease startup is synchronous and total live leases are bounded", context do
    state = state(context)

    tasks =
      for _ <- 1..64 do
        {:ok, task} =
          SourceTask.start(
            state,
            fn _owner ->
              receive do
                :release -> :drained
              after
                10_000 -> :expired
              end
            end,
            {:verification, "session"}
          )

        assert {task.pid, {:verification, "session"}} in Registry.lookup(
                 state.event_registry,
                 SourceTask
               )

        task
      end

    assert {:error, :source_operation_capacity} =
             SourceTask.start(state, fn _ -> flunk("over capacity") end)

    Enum.each(tasks, &send(&1.pid, :release))
    Enum.each(tasks, fn task -> assert Task.await(task, 5_000) == :drained end)
    assert wait_until(fn -> not SourceTask.busy?(state) end, 5_000)
  end

  test "a dead caller cannot start a new external operation after lease admission", context do
    state = state(context)
    caller = spawn(fn -> :ok end)
    ref = Process.monitor(caller)
    assert_receive {:DOWN, ^ref, :process, ^caller, _}, 5_000
    state = state |> Map.put(:source_operation_tasks, %{}) |> Map.put(:verified_changes, %{})
    state = put_in(state.projection.sessions["session"].verified_change.phase, "baseline")
    token = make_ref()
    operation = fn -> File.write!(Path.join(context.source, "forbidden"), "wrong") end

    assert {:reply, :ok, next} =
             SourceTask.admit(state, {:verification, "session"}, operation, token, caller)

    [task_ref] = Map.keys(next.source_operation_tasks)
    assert_receive {^task_ref, {:error, :source_caller_stopped} = result}, 5_000
    assert {:noreply, finished} = SourceTask.finish(next, task_ref, result)
    assert finished.source_operation_tasks == %{}
    refute File.exists?(Path.join(context.source, "forbidden"))
  end

  defp wait_until(predicate, remaining_ms) when remaining_ms > 0 do
    if predicate.() do
      true
    else
      receive do
      after
        10 -> wait_until(predicate, remaining_ms - 10)
      end
    end
  end

  defp wait_until(_predicate, _remaining_ms), do: false

  defp engine(state, simulator_opts \\ []) do
    start_supervised!({Registry, keys: :unique, name: __MODULE__.Agents})
    agents = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    config =
      RuntimeConfig.fresh(
        default_provider: :simulator,
        allow_simulator_provider: true,
        provider_discovery: false,
        agent_delay_ms: 0
      )

    opts = [
      name: __MODULE__.Engine,
      event_store: state.event_store,
      event_registry: state.event_registry,
      task_supervisor: state.task_supervisor,
      agent_registry: __MODULE__.Agents,
      agent_supervisor: agents,
      config: config,
      simulator_opts:
        Keyword.merge([seed: 0, delay_ms: 0, jitter_ms: 0, failure_rate: 0.0], simulator_opts)
    ]

    {start_supervised!({Engine, opts}), opts}
  end

  defp state(context) do
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    supervisor = start_supervised!(Task.Supervisor)

    store =
      start_supervised!(
        {EventStore, name: nil, path: Path.join(context.dir, "resolution.sqlite3")}
      )

    state = %{
      projection: Projector.initial(),
      event_store: store,
      event_registry: @event_registry,
      task_supervisor: supervisor,
      config: RuntimeConfig.fresh(provider_discovery: false),
      verified_change_resolution_tasks: %{}
    }

    room =
      {:room_created,
       %{
         "room_id" => "session",
         "slug" => "session",
         "title" => "Test",
         "workspace" => context.source,
         "participants" => []
       }, metadata()}

    state = Persistence.append_and_apply!(state, [room])

    phases =
      if context.change.phase == "blocked",
        do: ~w(preparing blocked),
        else: ~w(preparing baseline implementing verifying ready)

    Enum.reduce(phases, state, fn phase, acc ->
      change =
        if phase in ~w(preparing baseline),
          do: %{
            context.change
            | phase: phase,
              baseline: [],
              checks: [],
              patch: "",
              patch_hash: nil,
              error: nil
          },
          else: %{
            context.change
            | phase: phase,
              checks: if(phase in ["ready", "blocked"], do: context.change.checks, else: [])
          }

      Persistence.append_and_apply!(acc, [
        {:verified_change_recorded,
         %{"room_id" => "session", "record" => VerifiedChange.to_wire(change)}, metadata()}
      ])
    end)
  end

  defp requested(change),
    do: %Resolution{
      id: "resolution",
      change_id: change.id,
      patch_hash: change.patch_hash,
      decision: :apply,
      status: :requested,
      error: nil
    }

  defp entry(record),
    do:
      {:verified_change_resolution_recorded,
       %{"room_id" => "session", "record" => Resolution.to_wire(record)}, metadata()}

  defp metadata, do: [aggregate_type: :room, aggregate_id: "session", room_id: "session"]
  defp resolution(state), do: state.projection.sessions["session"].verified_change_resolution
  defp deadline, do: System.monotonic_time(:millisecond) + 60_000

  defp finish(state) do
    [ref] = Map.keys(state.verified_change_resolution_tasks)
    assert_receive {^ref, result}, 30_000
    {:noreply, state} = Handlers.finish(state, ref, result)
    state
  end

  defp decode(projection) do
    encoded = projection |> Checkpoint.encode_term() |> Jason.encode!()

    Checkpoint.decode(
      encoded,
      Checkpoint.projection_version(),
      projection.sequence,
      Hashing.sha256_hex(encoded),
      10_000_000
    )
  end

  defp commit!(source),
    do:
      git!(source, [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-qm",
        "fixture"
      ])

  defp git!(source, args) do
    {output, 0} = System.cmd("git", args, cd: source, stderr_to_stdout: true)
    output
  end
end
