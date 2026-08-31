defmodule ReyCode.Orchestration.Engine.Lifecycle do
  @moduledoc "Owns turn recovery, scheduling, cancellation, and finalization transitions."

  alias ReyCode.{Failure, ProjectInstructions}

  alias ReyCode.Orchestration.{
    ContextCompaction,
    Delegation,
    EventEntries,
    Mode,
    ToolRuns,
    Turn,
    Validation
  }

  alias ReyCode.Orchestration.Engine.{
    Admission,
    DelegationFinalization,
    Identity,
    Options,
    Persistence
  }

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

  def ensure_default_session(%{projection: %{session_order: []}} = state) do
    session_id = "session-reycode"

    {type, payload, metadata} =
      EventEntries.session_created(
        session_id,
        "reycode",
        "ReyCode",
        File.cwd!(),
        Options.default_participants(state.config.providers)
      )

    Persistence.append_and_project!(state, [{type, payload, metadata}])
  end

  def ensure_default_session(state), do: state

  @doc "Adds one primary participant to sessions created before the single-assistant policy."
  def ensure_primary_participants(state) do
    Enum.reduce(state.projection.session_order, state, &ensure_primary_participant(&2, &1))
  end

  defp ensure_primary_participant(state, session_id) do
    session = state.projection.sessions[session_id]

    if Enum.any?(session.participants, &(&1.kind == :primary)) do
      state
    else
      source =
        Enum.find(session.participants, &(not is_nil(&1.model))) ||
          List.first(session.participants)

      provider = if source, do: source.provider, else: state.config.providers.default_provider
      model = if source, do: source.model, else: nil

      entry =
        EventEntries.participant_added(
          session.id,
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

  def queue_message(state, session_id, body, mode, participant_id, retry_of_turn_id) do
    turn_id = Identity.new_id("turn")
    message_id = Identity.new_id("msg")
    context_sequence = state.projection.sequence + 1
    session = state.projection.sessions[session_id]

    input_kind =
      if session.active_turn_id || session.queued_turn_ids != [], do: :follow_up, else: :operator

    turn = %Turn{
      id: turn_id,
      session_id: session_id,
      mode: mode,
      participant_id: participant_id,
      input_kind: input_kind,
      retry_of_turn_id: retry_of_turn_id
    }

    entries = EventEntries.queue_turn(turn, body, message_id, context_sequence)

    next = Persistence.append_and_apply!(state, entries)
    session = next.projection.sessions[session_id]
    next = if session.active_turn_id == nil, do: start_turn(next, turn_id), else: next
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
      |> start_next_queued_turn(turn.session_id)
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

  defp start_next_queued_turn(state, session_id) do
    session = state.projection.sessions[session_id]

    if session.active_turn_id == nil and session.queued_turn_ids != [] do
      start_turn(state, hd(session.queued_turn_ids))
    else
      state
    end
  end

  def recover_session(state, session_id) do
    session = state.projection.sessions[session_id]

    cond do
      session.active_turn_id != nil -> recover_active_turn(state, session.active_turn_id)
      session.queued_turn_ids != [] -> start_turn(state, hd(session.queued_turn_ids))
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
    session = state.projection.sessions[turn.session_id]
    workflow = WorkflowDispatcher.for_mode(turn.mode)
    open_invocations(state, turn, workflow.plan(session, turn, state.projection))
  end

  def recover_invocations(state) do
    state.projection.invocations
    |> Map.values()
    |> Enum.sort_by(fn invocation ->
      state.projection.messages[invocation.message_id].created_sequence
    end)
    |> Enum.reduce(state, &recover_invocation(&2, &1))
    |> pump_admission()
    |> DelegationFinalization.resume_stale_delegations()
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

    DelegationFinalization.finalize_invocation(state, invocation.id, {:failed, error})
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

      DelegationFinalization.finalize_invocation(state, invocation.id, {:failed, error})
    end
  end

  defp start_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]

    if Mode.retired?(turn.mode),
      do: retire_legacy_turn(state, turn),
      else: start_supported_turn(state, turn)
  end

  defp start_supported_turn(state, turn) do
    session = state.projection.sessions[turn.session_id]
    specs = WorkflowDispatcher.for_mode(turn.mode).plan(session, turn, state.projection)
    invocation_entries = build_invocation_entries(session, turn, specs)
    turn_entry = EventEntries.turn_started(turn)

    context_entries =
      case ContextCompaction.entry(
             session,
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
    |> start_next_queued_turn(turn.session_id)
  end

  def advance_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]
    session = state.projection.sessions[turn.session_id]

    case WorkflowDispatcher.for_mode(turn.mode).advance(session, turn, state.projection) do
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

        session = state.projection.sessions[turn.session_id]

        cond do
          turn.detached? ->
            state

          session.queued_turn_ids == [] ->
            state

          true ->
            start_turn(state, hd(session.queued_turn_ids))
        end
    end
  end

  defp open_invocations(state, turn, specs) do
    session = state.projection.sessions[turn.session_id]
    entries = build_invocation_entries(session, turn, specs)

    state =
      if turn.mode == :squad do
        Persistence.append_and_apply!(state, EventEntries.squad_continue(turn, specs) ++ entries)
      else
        Persistence.append_and_apply!(state, entries)
      end

    start_invocation_workers(state, entries)
  end

  def build_invocation_entries(session, turn, specs) do
    capture = ProjectInstructions.capture(session.workspace)

    specs =
      Enum.map(specs, fn spec ->
        spec
        |> Map.put_new(:project_instructions, capture.content)
        |> Map.put_new(:project_instruction_digest, capture.digest)
        |> Map.put_new(:project_instruction_sources, capture.sources)
      end)

    generated_ids =
      Enum.map(specs, fn _spec -> {Identity.new_id("inv"), Identity.new_id("msg")} end)

    EventEntries.open_invocations(session, turn, specs, generated_ids)
  end

  def start_invocation_workers(state, entries) do
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

        DelegationFinalization.finalize_invocation(state, invocation.id, {:failed, error})
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
  def human_release_review?(turn) do
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

  def interrupted_failure,
    do: Failure.new(:interrupted, "The delegated task failed during recovery")

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
