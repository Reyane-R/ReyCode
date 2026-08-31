defmodule ReyCode.Orchestration.Engine.DelegationFinalization do
  @moduledoc """
  Delegation finalization for the Engine.

  Owns the end of the delegation path: resolving pending merge reviews by
  applying or discarding isolated patches, finalizing provider invocations,
  handing a finished child's report back to its suspended parent (single
  child or wave), and sweeping stale delegations during recovery.
  """

  alias ReyCode.Failure

  alias ReyCode.Orchestration.{Delegation, DelegationWorktree, EventEntries}

  alias ReyCode.Orchestration.Engine.{Admission, Lifecycle, Persistence}
  alias ReyCode.Orchestration.Workflow.Dispatcher, as: WorkflowDispatcher

  @type response :: {:reply, term(), map()}

  @doc "Applies or discards one pending isolated delegation patch and resumes finalization."
  @spec resolve_merge(map(), String.t(), atom() | String.t()) :: response()
  def resolve_merge(state, child_id, raw_decision) do
    child = state.projection.invocations[child_id]
    review = child && child.pending_tool_review
    parent = child && state.projection.invocations[child.delegated_from_invocation_id]
    run = parent && Map.get(parent.tool_runs, child.delegated_from_tool_run_id)

    with %{} <- child,
         %{tool: "merge"} <- review,
         %{} <- parent,
         %{} <- run,
         {:ok, decision} <- merge_decision(raw_decision),
         isolation when is_map(isolation) <- child.execution_context.isolation,
         :ok <- resolve_isolation(isolation, decision) do
      entry = EventEntries.delegation_merge_resolved(child, run, decision)
      next = Persistence.append_and_apply!(state, [entry])
      if decision == :apply, do: DelegationWorktree.cleanup(isolation)
      next = finalize_invocation(next, child.id, {:completed, %{"merge" => decision}})
      {:reply, :ok, next}
    else
      nil -> {:reply, {:error, :merge_review_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _other -> {:reply, {:error, :invalid_merge_review}, state}
    end
  end

  def finalize_invocation(state, invocation_id, outcome, prepend \\ []) do
    state = Lifecycle.release_execution(state, invocation_id)
    invocation = state.projection.invocations[invocation_id]

    if invocation == nil or invocation.status in [:completed, :failed, :cancelled] do
      state
    else
      case maybe_request_merge(state, invocation, outcome, prepend) do
        {:wait, next} -> Lifecycle.pump_admission(next)
        {:continue, next_outcome} -> finish_invocation(state, invocation, next_outcome, prepend)
      end
    end
  end

  defp finish_invocation(state, invocation, outcome, prepend) do
    turn = state.projection.turns[invocation.turn_id]
    message = state.projection.messages[invocation.message_id]
    outcome = detached_outcome(turn, invocation, message, outcome)

    opts = [
      human_release_review?:
        invocation.phase == "release_gate" and Lifecycle.human_release_review?(turn)
    ]

    next =
      turn.mode
      |> WorkflowDispatcher.for_mode()
      |> then(& &1.finalize(invocation, message, outcome, opts))
      |> apply_finalization(state, invocation, prepend)
      |> Lifecycle.pump_admission()

    resume_parent_delegation(next, invocation, outcome)
  end

  defp maybe_request_merge(state, child, {:completed, _metadata} = outcome, prepend) do
    isolation = child.execution_context.isolation

    cond do
      child.delegated_from_invocation_id == nil or isolation == nil ->
        {:continue, outcome}

      child.execution_context.merge_decision != nil ->
        {:continue, outcome}

      true ->
        request_merge_review(state, child, outcome, prepend)
    end
  end

  defp maybe_request_merge(_state, _child, outcome, _prepend), do: {:continue, outcome}

  defp request_merge_review(state, child, outcome, prepend) do
    parent = state.projection.invocations[child.delegated_from_invocation_id]
    run = parent && Map.get(parent.tool_runs, child.delegated_from_tool_run_id)
    body = state.projection.messages[child.message_id].body

    with %{} <- parent,
         %{} <- run,
         {:ok, _structured} <-
           Delegation.validate_output(body, child.execution_context.output_schema),
         {:ok, diff} <- merge_preview(child) do
      if diff == "" do
        {:continue, outcome}
      else
        entry = EventEntries.delegation_merge_requested(child, parent, run, diff)
        {:wait, Persistence.append_and_apply!(state, prepend ++ [entry])}
      end
    else
      {:error, reason} ->
        _ = finish_isolation(child, :cleanup)

        {:continue,
         {:failed,
          Failure.new(:delegation_contract_failed, "Merge review failed: #{inspect(reason)}")}}

      _other ->
        {:continue, outcome}
    end
  end

  defp merge_preview(child) do
    isolation = %{
      workspace: child.execution_context.isolation["workspace"],
      source_workspace: child.execution_context.isolation["source_workspace"]
    }

    DelegationWorktree.preview(isolation)
  end

  defp merge_decision(decision) when decision in [:approve, "approve", :apply, "apply"],
    do: {:ok, :apply}

  defp merge_decision(decision) when decision in [:deny, "deny", :discard, "discard"],
    do: {:ok, :discard}

  defp merge_decision(_decision), do: {:error, :invalid_merge_decision}

  defp resolve_isolation(isolation, :apply), do: DelegationWorktree.apply_keep(isolation)
  defp resolve_isolation(isolation, :discard), do: DelegationWorktree.cleanup(isolation)

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
        |> Lifecycle.pump_admission()
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
      |> Lifecycle.pump_admission()
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
          failure = child.error || Lifecycle.interrupted_failure()
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

  defp finish_isolation(%{execution_context: %{merge_decision: decision}}, _action)
       when decision in [:apply, :discard],
       do: :ok

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
  def resume_stale_delegations(state) do
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
        resume_parent_delegation(
          state,
          child,
          {:failed, child.error || Lifecycle.interrupted_failure()}
        )
    end
  end

  defp run_child_ids(%{child_invocation_ids: [], child_invocation_id: child_id}),
    do: List.wrap(child_id)

  defp run_child_ids(run), do: run.child_invocation_ids

  defp apply_finalization({:advance, entries}, state, invocation, prepend) do
    state
    |> Persistence.append_and_apply!(prepend ++ entries)
    |> Lifecycle.advance_turn(invocation.turn_id)
  end

  defp apply_finalization({:retry, entries, retry_spec}, state, invocation, prepend) do
    turn = state.projection.turns[invocation.turn_id]
    session = state.projection.sessions[invocation.session_id]
    invocation_entries = Lifecycle.build_invocation_entries(session, turn, [retry_spec])

    next = Persistence.append_and_apply!(state, prepend ++ entries ++ invocation_entries)
    Lifecycle.start_invocation_workers(next, invocation_entries)
  end
end
