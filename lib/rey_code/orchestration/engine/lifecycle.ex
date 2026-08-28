defmodule ReyCode.Orchestration.Engine.Lifecycle do
  @moduledoc "Owns turn recovery, scheduling, cancellation, and finalization transitions."

  alias ReyCode.{Failure, ProjectInstructions}

  alias ReyCode.Orchestration.{
    ContextCompaction,
    Delegation,
    DelegationWorktree,
    EventEntries,
    Mode,
    ToolRuns,
    Validation
  }

  alias ReyCode.Orchestration.Engine.{Admission, Identity, Options, Persistence}
  alias ReyCode.Orchestration.Workflow.Dispatcher, as: WorkflowDispatcher

  @worker_stop_timeout_ms 5_000

  def interrupt_started_runs(state, invocation) do
    invocation
    |> ToolRuns.running()
    |> Enum.reduce(state, fn run, acc ->
      entry = EventEntries.tool_run_interrupted(invocation, run, "worker_exit")
      Persistence.append_and_apply!(acc, [entry])
    end)
  end

  def ensure_default_room(%{projection: %{room_order: []}} = state) do
    room_id = "room-reycode"

    {type, payload, metadata} =
      EventEntries.room_created(
        room_id,
        "reycode",
        "ReyCode",
        File.cwd!(),
        Options.default_participants(state.config.providers)
      )

    Persistence.append_and_project!(state, [{type, payload, metadata}])
  end

  def ensure_default_room(state), do: state

  @doc "Adds one primary participant to rooms created before the single-assistant policy."
  def ensure_primary_participants(state) do
    Enum.reduce(state.projection.room_order, state, &ensure_primary_participant(&2, &1))
  end

  defp ensure_primary_participant(state, room_id) do
    room = state.projection.rooms[room_id]

    if Enum.any?(room.participants, &(&1.kind == :primary)) do
      state
    else
      source =
        Enum.find(room.participants, &(not is_nil(&1.model))) || List.first(room.participants)

      provider = if source, do: source.provider, else: state.config.providers.default_provider
      model = if source, do: source.model, else: nil

      entry =
        EventEntries.participant_added(
          room.id,
          "assistant",
          "Assistant",
          "general coding assistance",
          :primary,
          provider,
          model
        )

      Persistence.append_and_project!(state, [entry])
    end
  end

  def queue_message(state, room_id, body, mode, participant_id) do
    turn_id = Identity.new_id("turn")
    message_id = Identity.new_id("msg")
    context_sequence = state.projection.sequence + 1
    room = state.projection.rooms[room_id]

    input_kind =
      if room.active_turn_id || room.queued_turn_ids != [], do: :follow_up, else: :operator

    entries =
      EventEntries.queue_turn(
        room_id,
        body,
        mode,
        turn_id,
        message_id,
        context_sequence,
        input_kind,
        participant_id
      )

    next = Persistence.append_and_apply!(state, entries)
    room = next.projection.rooms[room_id]
    next = if room.active_turn_id == nil, do: start_turn(next, turn_id), else: next
    {:reply, {:ok, turn_id}, next}
  end

  def cancel_turn(state, turn_id, reason) do
    turn = state.projection.turns[turn_id]

    case Validation.cancellation(turn, reason) do
      {:ok, reason} when is_binary(reason) -> cancel_turn_invocations(state, turn, reason)
      {:ok, :already_finished} -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp cancel_turn_invocations(state, turn, reason) do
    invocations = cancellable_turn_invocations(state, turn)
    invocation_ids = Enum.map(invocations, & &1.id)

    next =
      state
      |> persist_turn_cancellation(turn, invocations, reason)
      |> Admission.drop_executions(invocation_ids)
      |> kill_cancelled_executions(invocation_ids)
      |> start_next_queued_turn(turn.room_id)
      |> pump_admission()

    {:ok, next}
  end

  defp cancellable_turn_invocations(state, turn) do
    turn.invocation_order
    |> Enum.map(&state.projection.invocations[&1])
    |> Enum.filter(
      &(&1.status in [
          :queued,
          :running,
          :waiting_tool_approval,
          :waiting_operator,
          :awaiting_delegation
        ])
    )
  end

  defp persist_turn_cancellation(state, turn, invocations, reason) do
    entries =
      delegation_cancellation_entries(invocations) ++
        EventEntries.cancel_turn(turn, invocations, reason)

    Persistence.append_and_apply!(state, entries)
  end

  # Cancelling mid-child fails the pending spawn_task run so a suspended
  # parent never waits on a child that will never report; both workers are
  # terminated exactly once by kill_cancelled_executions.
  defp delegation_cancellation_entries(invocations) do
    Enum.flat_map(invocations, fn invocation ->
      invocation
      |> ToolRuns.running()
      |> Enum.filter(&(&1.tool in [Delegation.tool_name(), Delegation.batch_tool_name()]))
      |> Enum.map(fn run ->
        EventEntries.tool_run_failed(invocation, run, %{
          "ok" => false,
          "error" => "turn_cancelled"
        })
      end)
    end)
  end

  defp kill_execution(state, invocation_id) do
    case Registry.lookup(state.agent_registry, invocation_id) do
      [{pid, _value} | _] -> Process.exit(pid, :kill)
      [] -> :ok
    end
  end

  defp kill_cancelled_executions(state, invocation_ids) do
    Enum.each(invocation_ids, &kill_execution(state, &1))
    state
  end

  defp start_next_queued_turn(state, room_id) do
    room = state.projection.rooms[room_id]

    if room.active_turn_id == nil and room.queued_turn_ids != [] do
      start_turn(state, hd(room.queued_turn_ids))
    else
      state
    end
  end

  def recover_room(state, room_id) do
    room = state.projection.rooms[room_id]

    cond do
      room.active_turn_id != nil -> recover_active_turn(state, room.active_turn_id)
      room.queued_turn_ids != [] -> start_turn(state, hd(room.queued_turn_ids))
      true -> state
    end
  end

  defp recover_active_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]

    cond do
      Mode.retired?(turn.mode) -> retire_legacy_turn(state, turn)
      turn.invocation_order == [] -> start_initial_invocations(state, turn)
      true -> advance_turn(state, turn_id)
    end
  end

  defp start_initial_invocations(state, turn) do
    room = state.projection.rooms[turn.room_id]
    workflow = WorkflowDispatcher.for_mode(turn.mode)
    open_invocations(state, turn, workflow.plan(room, turn, state.projection))
  end

  def recover_invocations(state) do
    state.projection.invocations
    |> Map.values()
    |> Enum.sort_by(fn invocation ->
      state.projection.messages[invocation.message_id].created_sequence
    end)
    |> Enum.reduce(state, &recover_invocation(&2, &1))
    |> pump_admission()
    |> resume_stale_delegations()
  end

  # A waiting approval is dormant: it holds no worker or admission slot and is
  # resumed only by the owner's resolution.
  defp recover_invocation(state, %{status: :waiting_tool_approval}), do: state
  defp recover_invocation(state, %{status: :waiting_operator}), do: state

  # A suspended parent is dormant like a waiting approval; it resumes only on
  # its child's terminal event or the stale-delegation sweep below.
  defp recover_invocation(state, %{status: :awaiting_delegation}), do: state

  defp recover_invocation(state, %{status: status}) when status not in [:queued, :running],
    do: state

  defp recover_invocation(state, %{status: :running} = invocation) do
    case ensure_no_started_runs(invocation) do
      :ok ->
        case Registry.lookup(state.agent_registry, invocation.id) do
          [{pid, _} | _] ->
            ref = Process.monitor(pid)
            Process.exit(pid, :kill)
            await_down!(ref, pid)
            recover_missing_execution(state, invocation)

          [] ->
            recover_missing_execution(state, invocation)
        end

      {:error, :indeterminate_tool_run} ->
        interrupt_and_fail(state, invocation, "recovered with a running tool run")
    end
  end

  defp recover_invocation(state, %{status: :queued} = invocation) do
    case Registry.lookup(state.agent_registry, invocation.id) do
      [{pid, _} | _] ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        await_down!(ref, pid)
        Admission.enqueue(state, invocation.id)

      [] ->
        Admission.enqueue(state, invocation.id)
    end
  end

  defp ensure_no_started_runs(invocation) do
    if ToolRuns.started?(invocation),
      do: {:error, :indeterminate_tool_run},
      else: :ok
  end

  defp interrupt_and_fail(state, invocation, reason) do
    state = interrupt_started_runs(state, invocation)

    error =
      Failure.new(
        :interrupted,
        "The provider invocation was interrupted mid tool run: #{reason}"
      )

    finalize_invocation(state, invocation.id, {:failed, error})
  end

  defp recover_missing_execution(state, invocation) do
    if replayable?(invocation.participant.provider) do
      Admission.enqueue(state, invocation.id)
    else
      error =
        Failure.new(
          :interrupted,
          "The provider invocation was interrupted and cannot be replayed safely"
        )

      finalize_invocation(state, invocation.id, {:failed, error})
    end
  end

  defp start_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]

    if Mode.retired?(turn.mode),
      do: retire_legacy_turn(state, turn),
      else: start_supported_turn(state, turn)
  end

  defp start_supported_turn(state, turn) do
    room = state.projection.rooms[turn.room_id]
    specs = WorkflowDispatcher.for_mode(turn.mode).plan(room, turn, state.projection)
    invocation_entries = build_invocation_entries(room, turn, specs)
    turn_entry = EventEntries.turn_started(turn)

    context_entries =
      case ContextCompaction.entry(
             room,
             state.projection,
             state.config.orchestration.context_budget_tokens
           ) do
        :unchanged -> []
        {:compact, entry} -> [entry]
      end

    state =
      if turn.mode == :squad do
        squad_config = [
          rework_budget: state.config.squad.rework_budget,
          release_authority:
            if(state.config.squad.release_gate_human?,
              do: :owner,
              else: :squad_leader
            )
        ]

        Persistence.append_and_apply!(
          state,
          context_entries ++
            [turn_entry | EventEntries.squad_start(turn, squad_config)] ++ invocation_entries
        )
      else
        Persistence.append_and_apply!(state, context_entries ++ [turn_entry | invocation_entries])
      end

    start_invocation_workers(state, invocation_entries)
  end

  defp retire_legacy_turn(state, turn) do
    cancellable = cancellable_turn_invocations(state, turn)
    invocation_ids = Enum.map(cancellable, & &1.id)
    reason = "Cancelled because the orchestration mode is retired"

    entries =
      EventEntries.cancel_invocations(cancellable, reason) ++
        [EventEntries.turn_completed(turn, :failed)]

    state
    |> Persistence.append_and_apply!(entries)
    |> Admission.drop_executions(invocation_ids)
    |> kill_cancelled_executions(invocation_ids)
    |> start_next_queued_turn(turn.room_id)
  end

  def advance_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]
    room = state.projection.rooms[turn.room_id]

    case WorkflowDispatcher.for_mode(turn.mode).advance(room, turn, state.projection) do
      :wait ->
        state

      {:continue, specs} ->
        open_invocations(state, turn, specs)

      {:complete, outcome} ->
        cancellable =
          if outcome == :failed, do: cancellable_turn_invocations(state, turn), else: []

        invocation_ids = Enum.map(cancellable, & &1.id)

        entries =
          EventEntries.cancel_invocations(cancellable, "Cancelled because the turn failed") ++
            [EventEntries.turn_completed(turn, outcome)]

        state =
          state
          |> Persistence.append_and_apply!(entries)
          |> Admission.drop_executions(invocation_ids)
          |> kill_cancelled_executions(invocation_ids)

        room = state.projection.rooms[turn.room_id]

        cond do
          turn.detached? ->
            state

          room.queued_turn_ids == [] ->
            state

          true ->
            start_turn(state, hd(room.queued_turn_ids))
        end
    end
  end

  defp open_invocations(state, turn, specs) do
    room = state.projection.rooms[turn.room_id]
    entries = build_invocation_entries(room, turn, specs)

    state =
      if turn.mode == :squad do
        Persistence.append_and_apply!(state, EventEntries.squad_continue(turn, specs) ++ entries)
      else
        Persistence.append_and_apply!(state, entries)
      end

    start_invocation_workers(state, entries)
  end

  defp build_invocation_entries(room, turn, specs) do
    capture = ProjectInstructions.capture(room.workspace)

    specs =
      Enum.map(specs, fn spec ->
        spec
        |> Map.put_new(:project_instructions, capture.content)
        |> Map.put_new(:project_instruction_digest, capture.digest)
        |> Map.put_new(:project_instruction_sources, capture.sources)
      end)

    generated_ids =
      Enum.map(specs, fn _spec -> {Identity.new_id("inv"), Identity.new_id("msg")} end)

    EventEntries.open_invocations(room, turn, specs, generated_ids)
  end

  defp start_invocation_workers(state, entries) do
    entries
    |> Enum.reduce(state, fn {_type, payload, _metadata}, acc ->
      Admission.enqueue(acc, payload["invocation_id"])
    end)
    |> pump_admission()
  end

  def pump_admission(state) do
    case Admission.next_eligible(state) do
      nil ->
        state

      {invocation_id, index} ->
        state = Admission.dequeue(state, {invocation_id, index})

        invocation = state.projection.invocations[invocation_id]

        if invocation == nil or invocation.status in [:completed, :failed, :cancelled] do
          pump_admission(state)
        else
          invocation |> start_execution(state) |> pump_admission()
        end
    end
  end

  defp start_execution(invocation, state) do
    spec =
      {ReyCode.Agent,
       engine: state.name,
       registry: state.agent_registry,
       invocation_id: invocation.id,
       provider: invocation.participant.provider,
       provider_catalog: state.provider_catalog,
       config: state.config}

    case DynamicSupervisor.start_child(state.agent_supervisor, spec) do
      {:ok, pid} ->
        monitor_execution(state, invocation.id, pid)

      {:error, {:already_started, pid}} ->
        monitor_execution(state, invocation.id, pid)

      {:error, reason} ->
        error =
          Failure.new(
            :worker_start_failed,
            "Could not start provider worker: #{inspect(reason)}",
            true
          )

        finalize_invocation(state, invocation.id, {:failed, error})
    end
  end

  defp monitor_execution(state, invocation_id, pid) do
    ref = Process.monitor(pid)
    workspace = Admission.workspace(state, invocation_id)

    state
    |> put_in([:agent_monitors, ref], invocation_id)
    |> put_in([:active_executions, invocation_id], workspace)
  end

  def release_execution(state, invocation_id) do
    %{state | active_executions: Map.delete(state.active_executions, invocation_id)}
  end

  # Release-gate authority is frozen at turn start (squad_configured carries it);
  # flipping the runtime env mid-turn does not change an in-flight squad.
  defp human_release_review?(turn) do
    turn.squad != nil and turn.squad.release_authority == :owner
  end

  def budget_extension_entries(%{squad: squad} = turn, :rework)
      when squad.rework_count >= squad.rework_budget,
      do: [
        EventEntries.squad_budget_extended(
          turn,
          max(squad.rework_budget, squad.rework_count) + 1
        )
      ]

  def budget_extension_entries(_turn, _decision), do: []

  def finalize_invocation(state, invocation_id, outcome, prepend \\ []) do
    state = release_execution(state, invocation_id)
    invocation = state.projection.invocations[invocation_id]

    next =
      if invocation == nil or invocation.status in [:completed, :failed, :cancelled] do
        state
      else
        turn = state.projection.turns[invocation.turn_id]
        message = state.projection.messages[invocation.message_id]
        outcome = detached_outcome(turn, invocation, message, outcome)

        opts = [
          human_release_review?:
            invocation.phase == "release_gate" and human_release_review?(turn)
        ]

        turn.mode
        |> WorkflowDispatcher.for_mode()
        |> then(& &1.finalize(invocation, message, outcome, opts))
        |> apply_finalization(state, invocation, prepend)
      end

    next = pump_admission(next)
    resume_parent_delegation(next, invocation, outcome)
  end

  defp detached_outcome(%{detached?: false}, _invocation, _message, outcome), do: outcome

  defp detached_outcome(_turn, child, message, {:completed, metadata}) do
    with {:ok, _structured} <-
           Delegation.validate_output(message.body, child.execution_context.output_schema),
         :ok <- finish_isolation(child, :apply) do
      {:completed, metadata}
    else
      {:error, reason} ->
        _ = finish_isolation(child, :cleanup)

        {:failed,
         Failure.new(
           :delegation_contract_failed,
           "Detached delegation contract failed: #{inspect(reason)}"
         )}
    end
  end

  defp detached_outcome(_turn, child, _message, outcome) do
    _ = finish_isolation(child, :cleanup)
    outcome
  end

  # A finished child hands its structured report to the suspended parent as
  # the spawn_task run's result and re-arms parent admission. Guarded by the
  # run's :running status, so replaying or re-entering resolves exactly once.
  defp resume_parent_delegation(state, %{delegated_from_invocation_id: nil}, _outcome),
    do: state

  defp resume_parent_delegation(state, child, outcome) do
    parent = state.projection.invocations[child.delegated_from_invocation_id]
    run = parent && Map.get(parent.tool_runs, child.delegated_from_tool_run_id)

    cond do
      parent == nil or run == nil or run.status != :running ->
        state

      run.tool == Delegation.batch_tool_name() ->
        resume_delegation_wave(state, parent, run)

      outcome == :cancelled ->
        _ = finish_isolation(child, :cleanup)
        state

      true ->
        entry = delegation_result_entry(parent, run, child, outcome, state.projection)

        state
        |> Persistence.append_and_apply!([entry])
        |> Admission.enqueue(parent.id)
        |> pump_admission()
    end
  end

  defp resume_delegation_wave(state, parent, run) do
    children = Enum.map(run.child_invocation_ids, &state.projection.invocations[&1])

    if children != [] and Enum.all?(children, &(&1.status in [:completed, :failed, :cancelled])) do
      reports = Enum.map(children, &wave_child_report(&1, state.projection))
      output = Jason.encode!(%{"tasks" => reports})
      result = Delegation.report(true, output, aggregate_wave_usage(children))
      entry = EventEntries.tool_run_completed(parent, run, result)

      state
      |> Persistence.append_and_apply!([entry])
      |> Admission.enqueue(parent.id)
      |> pump_admission()
    else
      state
    end
  end

  defp wave_child_report(child, projection) do
    body = projection.messages[child.message_id] && projection.messages[child.message_id].body
    role = if child.dependencies == [], do: "worker", else: "integrator"

    result =
      cond do
        child.status == :completed ->
          with {:ok, structured} <-
                 Delegation.validate_output(body, child.execution_context.output_schema),
               :ok <- finish_isolation(child, :apply) do
            %{"ok" => true, "output" => structured}
          else
            {:error, reason} ->
              _ = finish_isolation(child, :cleanup)
              %{"ok" => false, "error" => inspect(reason)}
          end

        child.status == :failed ->
          _ = finish_isolation(child, :cleanup)
          failure = child.error || interrupted_failure()
          %{"ok" => false, "error" => Failure.to_wire(failure)}

        true ->
          _ = finish_isolation(child, :cleanup)
          %{"ok" => false, "error" => "cancelled"}
      end

    Map.merge(result, %{
      "invocation_id" => child.id,
      "agent" => child.participant.name,
      "role" => role,
      "usage" => child.usage || %{}
    })
  end

  defp aggregate_wave_usage(children) do
    %{"children" => Enum.map(children, &(&1.usage || %{}))}
  end

  defp delegation_report(child, {:failed, error}, _projection) do
    wire = Failure.to_wire(error)
    Delegation.report(false, "#{wire["category"]}: #{wire["message"]}", child.usage)
  end

  defp delegation_result_entry(parent, run, child, {:completed, _metadata}, projection) do
    body = projection.messages[child.message_id] && projection.messages[child.message_id].body

    with {:ok, _structured} <-
           Delegation.validate_output(body, child.execution_context.output_schema),
         :ok <- finish_isolation(child, :apply) do
      EventEntries.tool_run_completed(
        parent,
        run,
        Delegation.report(true, body, child.usage)
      )
    else
      {:error, reason} ->
        _ = finish_isolation(child, :cleanup)

        EventEntries.tool_run_failed(
          parent,
          run,
          Delegation.report(false, inspect(reason), child.usage)
        )
    end
  end

  defp delegation_result_entry(parent, run, child, {:failed, error}, projection) do
    _ = finish_isolation(child, :cleanup)

    EventEntries.tool_run_failed(
      parent,
      run,
      delegation_report(child, {:failed, error}, projection)
    )
  end

  defp finish_isolation(%{execution_context: %{isolation: nil}}, _action), do: :ok

  defp finish_isolation(child, action) do
    isolation = %{
      workspace: child.execution_context.isolation["workspace"],
      source_workspace: child.execution_context.isolation["source_workspace"]
    }

    case action do
      :apply -> DelegationWorktree.apply(isolation)
      :cleanup -> DelegationWorktree.cleanup(isolation)
    end
  end

  # Crash between a child's terminal record and the parent's resume write
  # leaves a suspended parent with a finished child; recovery completes the
  # handoff exactly once. Children recover first (created earlier in the sort,
  # enqueued during the reduce), so parents resume after them.
  defp resume_stale_delegations(state) do
    state.projection.invocations
    |> Map.values()
    |> Enum.filter(&(&1.status == :awaiting_delegation))
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(state, &resume_stale_delegation/2)
  end

  defp resume_stale_delegation(parent, state) do
    case pending_spawn_run(parent) do
      nil -> state
      run -> resume_stale_child(state, run)
    end
  end

  defp pending_spawn_run(parent) do
    parent.tool_run_order
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.map(&parent.tool_runs[&1])
    |> Enum.find(fn run ->
      run != nil and
        run.tool in [Delegation.tool_name(), Delegation.batch_tool_name()] and
        run.status == :running and run_child_ids(run) != []
    end)
  end

  defp resume_stale_child(state, run) do
    children = Enum.map(run_child_ids(run), &state.projection.invocations[&1])

    case Enum.find(children, &(&1 && &1.status in [:completed, :failed])) do
      nil ->
        state

      %{status: :completed} = child ->
        resume_parent_delegation(state, child, {:completed, nil})

      %{status: :failed} = child ->
        resume_parent_delegation(state, child, {:failed, child.error || interrupted_failure()})
    end
  end

  defp run_child_ids(%{child_invocation_ids: [], child_invocation_id: child_id}),
    do: List.wrap(child_id)

  defp run_child_ids(run), do: run.child_invocation_ids

  defp interrupted_failure,
    do: Failure.new(:interrupted, "The delegated task failed during recovery")

  defp apply_finalization({:advance, entries}, state, invocation, prepend) do
    state
    |> Persistence.append_and_apply!(prepend ++ entries)
    |> advance_turn(invocation.turn_id)
  end

  defp apply_finalization({:retry, entries, retry_spec}, state, invocation, prepend) do
    turn = state.projection.turns[invocation.turn_id]
    room = state.projection.rooms[invocation.room_id]
    invocation_entries = build_invocation_entries(room, turn, [retry_spec])

    next = Persistence.append_and_apply!(state, prepend ++ entries ++ invocation_entries)
    start_invocation_workers(next, invocation_entries)
  end

  defp await_down!(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @worker_stop_timeout_ms ->
        raise "provider worker did not stop within #{@worker_stop_timeout_ms}ms"
    end
  end

  def replayable?(:simulator), do: true
  def replayable?("simulator"), do: true
  def replayable?(_provider), do: false
end
