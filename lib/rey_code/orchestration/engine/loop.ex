defmodule ReyCode.Orchestration.Engine.Loop do
  @moduledoc "Handles the durable AgentLoop process protocol for the Engine."

  alias ReyCode.Failure

  alias ReyCode.Orchestration.{
    Delegation,
    EventEntries,
    InvocationRequest,
    ToolRun,
    ToolRuns,
    Validation
  }

  alias ReyCode.Orchestration.Engine.{
    Admission,
    Identity,
    Lifecycle,
    Persistence,
    ProviderFrames
  }

  alias ReyCode.Provider.Response
  alias ReyCode.ToolRegistry

  @delegation_tool Delegation.tool_name()

  @type response :: {:reply, term(), map()}

  @doc "Builds the current durable request for one invocation."
  @spec request(map(), term()) :: response()
  def request(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    reply =
      cond do
        invocation == nil ->
          {:terminal, :missing}

        invocation.status in [:completed, :failed, :cancelled] ->
          {:terminal, invocation.status}

        invocation.status == :awaiting_delegation ->
          {:waiting, :delegation}

        invocation.status == :waiting_tool_approval ->
          {:waiting, :tool_approval}

        true ->
          {:ok,
           InvocationRequest.build(invocation, state.projection, %{
             agent_delay_ms: state.agent_delay_ms,
             simulator_opts: state.simulator_opts
           })}
      end

    {:reply, reply, state}
  end

  @doc "Records that one queued invocation has started."
  @spec started(map(), term()) :: response()
  def started(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    if invocation && invocation.status == :queued do
      {:reply, :ok,
       Persistence.append_and_apply!(state, [EventEntries.invocation_started(invocation)])}
    else
      {:reply, :ok, state}
    end
  end

  @doc "Validates and records a batch of provider frames."
  @spec record_frames(map(), term(), term()) :: response()
  def record_frames(state, invocation_id, frames) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      not is_list(frames) ->
        {:reply, {:error, :invalid_frames}, state}

      true ->
        case ProviderFrames.collect(invocation, frames) do
          {:ok, []} ->
            {:reply, :ok, state}

          {:ok, pending_frames} ->
            append_pending_frames(state, invocation, pending_frames)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @doc "Validates and records one provider frame."
  @spec record_frame(map(), term(), term()) :: response()
  def record_frame(state, invocation_id, frame), do: record_frames(state, invocation_id, [frame])

  @doc "Validates and records one normalized provider round."
  @spec record_round(map(), term(), term(), term()) :: response()
  def record_round(state, invocation_id, round_index, response_wire) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      invocation.status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :invocation_terminal}, state}

      true ->
        persist_round(state, invocation, round_index, response_wire)
    end
  end

  def take_tool_run(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      invocation.status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :invocation_terminal}, state}

      invocation.status == :awaiting_delegation ->
        {:reply, {:waiting, :delegation}, state}

      true ->
        next_tool_run(state, invocation)
    end
  end

  @doc "Records one owner decision for a durable tool run."
  @spec resolve_tool_run(map(), term(), term(), term()) :: response()
  def resolve_tool_run(state, invocation_id, run_id, raw_decision) do
    invocation = state.projection.invocations[invocation_id]

    with {:ok, review, decision} <-
           Validation.tool_run_resolution(invocation, run_id, raw_decision),
         {:ok, run} <- resumable_run(invocation, review) do
      {:reply, :ok, resolve_tool_decision(state, invocation, run, decision)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc "Transitions one ready tool run to running."
  @spec tool_run_started(map(), term(), term()) :: response()
  def tool_run_started(state, invocation_id, run_id) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :ready) do
      entry = EventEntries.tool_run_started(invocation, run)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Records one successful tool-run result."
  @spec tool_run_completed(map(), term(), term(), term()) :: response()
  def tool_run_completed(state, invocation_id, run_id, result) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :running),
         :ok <- ensure_wire_map(result) do
      entry = EventEntries.tool_run_completed(invocation, run, result)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Records one failed tool-run result."
  @spec tool_run_failed(map(), term(), term(), term()) :: response()
  def tool_run_failed(state, invocation_id, run_id, error) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :running),
         :ok <- ensure_wire_map(error) do
      entry = EventEntries.tool_run_failed(invocation, run, error)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Finalizes one invocation as completed."
  @spec complete(map(), term(), term()) :: response()
  def complete(state, invocation_id, metadata) do
    {:reply, :ok, Lifecycle.finalize_invocation(state, invocation_id, {:completed, metadata})}
  end

  @doc "Finalizes one invocation as failed."
  @spec fail(map(), term(), term()) :: response()
  def fail(state, invocation_id, error) do
    {:reply, :ok, Lifecycle.finalize_invocation(state, invocation_id, {:failed, error})}
  end

  defp append_pending_frames(state, invocation, pending_frames) do
    if invocation.status in [:completed, :failed, :cancelled] do
      {:reply, {:error, :invocation_terminal}, state}
    else
      entries = Enum.map(pending_frames, &EventEntries.provider_frame(invocation, &1))
      {:reply, :ok, Persistence.append_and_apply!(state, entries)}
    end
  end

  defp persist_round(state, invocation, round_index, response_wire) do
    with {:ok, response} <- Response.from_wire(response_wire),
         :ok <- round_contiguous?(invocation, round_index) do
      entry = EventEntries.provider_round(invocation, round_index, response_wire)
      state = Persistence.append_and_apply!(state, [entry])

      if response.tool_calls == [] do
        {:reply, {:ok, :final}, state}
      else
        {:reply, {:ok, :continue}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp round_contiguous?(invocation, round_index) do
    if round_index == length(invocation.rounds),
      do: :ok,
      else: {:error, :invalid_round_index}
  end

  defp next_tool_run(state, invocation) do
    case ToolRuns.next_action(invocation) do
      :none ->
        {:reply, {:ok, :none}, state}

      {:new, call} ->
        claim_new_run(state, invocation, call)

      {:existing, action, run} ->
        {:reply, {:ok, {action, run}}, state}
    end
  end

  defp claim_new_run(state, invocation, %{tool: tool} = call) when tool == @delegation_tool do
    claim_delegation(state, invocation, call)
  end

  defp claim_new_run(state, invocation, call) do
    run = %ToolRun{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(state.projection.rooms[invocation.room_id].workspace)
    }

    authorization =
      if ToolRegistry.requires_approval?(call.tool) do
        :ask
      else
        if call.tool in ToolRegistry.tool_names(), do: :allow, else: :denied
      end

    run = %{run | authorization: authorization}

    entries =
      case authorization do
        :denied ->
          [
            EventEntries.tool_run_requested(invocation, run),
            EventEntries.tool_run_failed(invocation, run, %{
              "ok" => false,
              "error" => "unknown_tool"
            })
          ]

        _other ->
          [EventEntries.tool_run_requested(invocation, run)]
      end

    next = Persistence.append_and_apply!(state, entries)
    run = next.projection.invocations[invocation.id].tool_runs[run.id]

    next =
      if authorization == :ask,
        do: Lifecycle.advance_turn(next, invocation.turn_id),
        else: next

    action = if authorization == :denied, do: :denied, else: authorization_action(authorization)
    {:reply, {:ok, {action, run}}, next}
  end

  defp authorization_action(:allow), do: :execute
  defp authorization_action(:ask), do: :await

  # spawn_task is claimed here and never reaches ToolRegistry.execute: the run
  # stays :running while the child invocation executes, and the parent worker
  # stops with zero further provider rounds until the child terminates.
  defp claim_delegation(state, invocation, call) do
    run = %ToolRun{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(state.projection.rooms[invocation.room_id].workspace),
      authorization: :allow
    }

    case Delegation.authorize(
           invocation,
           call.arguments,
           state.projection,
           delegation_bounds(state)
         ) do
      {:ok, participant} ->
        open_child_delegation(state, invocation, run, participant)

      {:error, reason} ->
        entries = [
          EventEntries.tool_run_requested(invocation, %{run | authorization: :denied}),
          EventEntries.tool_run_failed(invocation, run, %{
            "ok" => false,
            "error" => Atom.to_string(reason)
          })
        ]

        next = Persistence.append_and_apply!(state, entries)
        denied = next.projection.invocations[invocation.id].tool_runs[run.id]
        {:reply, {:ok, {:denied, denied}}, next}
    end
  end

  defp open_child_delegation(state, invocation, run, participant) do
    room = state.projection.rooms[invocation.room_id]
    turn = state.projection.turns[invocation.turn_id]
    child_id = Identity.new_id("inv")
    child_message_id = Identity.new_id("msg")
    depth = invocation.delegation_depth + 1
    brief = run.arguments["brief"]

    child_spec = %{
      participant_id: participant.id,
      phase_index: 0,
      label: "delegated task",
      system_prompt: Delegation.child_system_prompt(participant, brief),
      delegated_from_invocation_id: invocation.id,
      delegated_from_tool_run_id: run.id,
      delegation_depth: depth
    }

    entries =
      [
        EventEntries.tool_run_requested(invocation, run),
        EventEntries.tool_run_started(invocation, %{run | status: :ready})
      ] ++
        EventEntries.open_invocations(room, turn, [child_spec], [{child_id, child_message_id}]) ++
        [EventEntries.delegation_opened(invocation, run, child_id, child_message_id, depth)]

    next =
      state
      |> Persistence.append_and_apply!(entries)
      |> Admission.enqueue(child_id)
      |> Lifecycle.pump_admission()

    pending = next.projection.invocations[invocation.id].tool_runs[run.id]
    {:reply, {:ok, {:delegate, pending}}, next}
  end

  defp delegation_bounds(state) do
    orchestration = state.config.orchestration

    %{
      max_children: orchestration.delegation_max_children,
      brief_max_bytes: orchestration.delegation_brief_max_bytes
    }
  end

  defp fetch_invocation(state, invocation_id) do
    case state.projection.invocations[invocation_id] do
      nil -> {:error, :invocation_not_found}
      invocation -> {:ok, invocation}
    end
  end

  defp ensure_wire_map(value) when is_map(value), do: :ok
  defp ensure_wire_map(_value), do: {:error, :invalid_tool_run_payload}

  defp resumable_run(invocation, review) do
    case Map.get(invocation.tool_runs, review.request_id) do
      %{status: :awaiting_approval} = run ->
        {:ok, run}

      _other ->
        {:error, :legacy_tool_approval_unresumable}
    end
  end

  defp resolve_tool_decision(state, invocation, run, :approve) do
    entry = EventEntries.tool_run_approval_resolved(invocation, run, :approve)

    state
    |> Persistence.append_and_apply!([entry])
    |> Admission.enqueue(invocation.id)
    |> Lifecycle.pump_admission()
  end

  # A denial and its terminal failure must share one durable transaction:
  # persisting them separately could crash between the writes and strand the
  # invocation in :waiting_tool_approval with no review left to resolve.
  defp resolve_tool_decision(state, invocation, run, :deny) do
    denial = EventEntries.tool_run_approval_resolved(invocation, run, :deny)

    Lifecycle.finalize_invocation(state, invocation.id, {:failed, tool_denied_error()}, [denial])
  end

  defp tool_denied_error, do: Failure.new(:tool_denied, "Tool request denied")
end
