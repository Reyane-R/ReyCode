defmodule ReyCode.Orchestration.Workflow.Squad do
  @moduledoc false
  @behaviour ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.{Squad, SquadFSM}
  alias ReyCode.Orchestration.Workflow.Squad.Finalizer

  @impl true
  def plan(session, turn, projection) do
    specs_for_phase(planning_context(session, turn, projection), 0, 0)
  end

  @impl true
  def advance(session, turn, projection) do
    phase = turn.squad.phase_index
    cycle = turn.squad.cycle
    invocations = current_invocations(turn, projection, phase, cycle)

    cond do
      invocations == [] or Enum.any?(invocations, &(&1.status in [:queued, :running])) ->
        :wait

      newest_failed?(invocations) ->
        {:complete, :failed}

      not phase_outputs_complete?(turn.squad, phase, cycle) ->
        :wait

      true ->
        transition(session, turn, projection)
    end
  end

  @impl true
  def finalize(invocation, message, outcome, opts),
    do: Finalizer.finalize(invocation, message, outcome, opts)

  @doc "Builds invocation specs for one phase and rework cycle."
  def specs_for_phase(context, phase_index, cycle) do
    phase = Squad.phase(phase_index)
    spec_context = invocation_spec_context(context, phase, phase_index, cycle)

    Enum.map(phase.role_ids, &invocation_spec(&1, spec_context))
  end

  defp transition(session, turn, projection) do
    state = fsm_from_turn(turn)

    result =
      if Squad.gate?(state.phase_index) do
        resolution = latest_resolution(turn.squad, state.phase_index, state.cycle)
        SquadFSM.gate(state, resolution)
      else
        SquadFSM.next(state)
      end

    case result do
      {:continue, next} ->
        context = planning_context(session, turn, projection)
        {:continue, specs_for_phase(context, next.phase_index, next.cycle)}

      {:complete, next} ->
        {:complete, SquadFSM.outcome(next)}

      {:error, _reason} ->
        {:complete, :failed}
    end
  end

  defp current_invocations(turn, projection, phase, cycle) do
    turn.invocation_order
    |> Enum.map(&projection.invocations[&1])
    |> Enum.filter(&(&1.phase_index == phase and &1.cycle == cycle))
    |> Enum.group_by(& &1.logical_work_id)
    |> Enum.map(fn {_logical_work_id, attempts} -> Enum.max_by(attempts, & &1.attempt) end)
  end

  defp newest_failed?(invocations), do: Enum.any?(invocations, &(&1.status == :failed))

  defp phase_outputs_complete?(squad, phase_index, cycle) do
    phase = Squad.phase(phase_index)

    if Squad.gate?(phase) do
      latest_resolution(squad, phase_index, cycle) != nil
    else
      artifact_kinds =
        squad.artifacts
        |> Enum.filter(&(&1.phase == phase.id and &1.cycle == cycle))
        |> MapSet.new(& &1.kind)

      Squad.phase_artifacts_complete?(phase, artifact_kinds)
    end
  end

  defp latest_resolution(squad, phase_index, cycle) do
    phase = Squad.phase(phase_index)

    Enum.find(squad.resolutions, fn resolution ->
      resolution.phase == phase.id and resolution.cycle == cycle
    end)
  end

  defp dependency_ids(turn, projection) do
    turn.invocation_order
    |> Enum.map(&projection.invocations[&1])
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.map(& &1.id)
  end

  defp logical_work_id(turn_id, phase, cycle, role_id),
    do: Enum.join([turn_id, phase, cycle, role_id], ":")

  defp system_prompt(role, phase, cycle, directives) do
    output =
      if Squad.gate?(phase) do
        ~s({"kind":"gate","decision":"approve|rework|abort","target_phase":null,"reasons":[]})
      else
        phase.id |> Squad.required_artifacts(role.id) |> artifact_envelope()
      end

    """
    You are the #{role.name} in ReyCode's fixed squad workflow.
    Responsibility: #{role.perspective}.
    Current phase: #{phase.id}. Rework cycle: #{cycle}.
    #{directive_prompt(directives)}
    Return only one JSON object matching this envelope: #{output}
    Do not wrap the JSON in Markdown.
    """
  end

  defp directive_prompt([]), do: ""

  defp directive_prompt(directives) do
    rendered =
      directives
      |> Enum.reverse()
      |> Enum.map_join("\n", &"- #{&1.text}")

    "Owner directives that apply to this work:\n#{rendered}"
  end

  defp artifact_envelope([artifact]) do
    ~s({"kind":"artifact","artifact_type":"#{artifact}","summary":"...","blockers":[]})
  end

  defp artifact_envelope(artifacts) do
    envelopes =
      Enum.map(artifacts, fn artifact ->
        %{"artifact_type" => artifact, "summary" => "...", "blockers" => []}
      end)

    Jason.encode!(%{"kind" => "artifacts", "artifacts" => envelopes})
  end

  defp planning_context(session, turn, projection) do
    %{session: session, turn: turn, projection: projection}
  end

  defp invocation_spec_context(context, phase, phase_index, cycle) do
    %{
      session: context.session,
      turn: context.turn,
      phase: phase,
      phase_index: phase_index,
      cycle: cycle,
      dependencies: dependency_ids(context.turn, context.projection),
      directives: (context.turn.squad && context.turn.squad.directives) || []
    }
  end

  defp invocation_spec(role_id, context) do
    role = Squad.role(role_id)
    participant = Map.fetch!(context.session.squad_seats, role_id)

    %{
      participant_id: role_id,
      participant: participant,
      phase_index: context.phase_index,
      phase: context.phase.id,
      cycle: context.cycle,
      logical_work_id: logical_work_id(context.turn.id, context.phase.id, context.cycle, role_id),
      dependencies: context.dependencies,
      attempt: 1,
      label: context.phase.id,
      system_prompt: system_prompt(role, context.phase, context.cycle, context.directives)
    }
  end

  defp fsm_from_turn(turn) do
    %SquadFSM{
      session_id: turn.session_id,
      phase_index: turn.squad.phase_index,
      cycle: turn.squad.cycle,
      rework_count: turn.squad.rework_count,
      rework_budget: turn.squad.rework_budget,
      outcome: nil
    }
  end
end
