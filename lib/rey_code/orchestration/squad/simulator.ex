defmodule ReyCode.Orchestration.Squad.Simulator do
  @moduledoc "Pure seeded simulator that drives SquadFSM without processes or sleeping."

  alias ReyCode.Orchestration.{Squad, SquadFSM}
  alias ReyCode.Provider.Simulator.Scenario
  alias ReyCode.Retry

  @type result :: %{
          outcome: :completed | :failed,
          state: SquadFSM.t(),
          steps: non_neg_integer(),
          events: [map()],
          artifacts: [map()],
          failures: [map()],
          max_delay_ms: non_neg_integer()
        }

  @typep accumulator :: %{
           steps: non_neg_integer(),
           events: [map()],
           artifacts: [map()],
           failures: [map()],
           max_delay_ms: non_neg_integer()
         }

  @typep context :: %{
           state: SquadFSM.t(),
           scenario: Scenario.t(),
           result: accumulator()
         }

  @typep step :: %{
           context: context(),
           phase: Squad.phase(),
           role_id: String.t(),
           attempt: pos_integer()
         }

  @doc "Runs a deterministic squad simulation from scenario options or a scenario."
  @spec run(keyword() | Scenario.t()) :: result()
  def run(%Scenario{} = scenario), do: scenario |> initial_context() |> simulate()
  def run(opts), do: opts |> Scenario.new() |> run()

  defp simulate(%{state: state, result: result} = context) do
    cond do
      SquadFSM.complete?(state) ->
        finish(context)

      result.steps >= step_limit(state) ->
        context |> fail() |> finish()

      true ->
        execute_current_phase(context)
    end
  end

  defp execute_current_phase(%{state: state} = context) do
    phase = Squad.phase(state.phase_index)

    case execute_phase(context, phase) do
      {:ok, outputs, next_context} -> transition(next_context, phase, outputs)
      {:error, next_context} -> next_context |> fail() |> finish()
    end
  end

  defp execute_phase(context, phase) do
    Enum.reduce_while(phase.role_ids, {:ok, [], context}, fn role_id, {:ok, outputs, context} ->
      case execute_role(new_step(context, phase, role_id)) do
        {:ok, output, next_context} -> {:cont, {:ok, [output | outputs], next_context}}
        {:error, next_context} -> {:halt, {:error, next_context}}
      end
    end)
  end

  @spec new_step(context(), Squad.phase(), String.t()) :: step()
  defp new_step(context, phase, role_id) do
    %{context: context, phase: phase, role_id: role_id, attempt: 1}
  end

  defp execute_role(step) do
    sample = Scenario.sample(step.context.scenario, request_for(step))
    step = record_sample(step, sample)

    resolve_sample(step, sample.failure)
  end

  defp request_for(%{context: %{state: state}, phase: phase} = step) do
    %{
      turn_id: "simulation",
      logical_work_id: Enum.join([phase.id, state.cycle, step.role_id], ":"),
      attempt: step.attempt,
      phase: phase.id,
      participant: %{id: step.role_id}
    }
  end

  defp record_sample(%{context: %{result: result} = context} = step, sample) do
    result = %{
      result
      | steps: result.steps + 1,
        max_delay_ms: max(result.max_delay_ms, sample.delay_ms)
    }

    %{step | context: %{context | result: result}}
  end

  defp resolve_sample(step, nil) do
    output = simulated_output(step)
    {:ok, output, record_output(step, output)}
  end

  defp resolve_sample(step, failure) do
    step = record_failure(step, failure)

    if Retry.retryable?(Scenario.failure_error(failure)) and
         step.attempt < Squad.retry_limit() do
      execute_role(%{step | attempt: step.attempt + 1})
    else
      {:error, step.context}
    end
  end

  defp record_output(
         %{context: %{state: state, result: result} = context, phase: phase} = step,
         output
       ) do
    event = %{type: output["kind"], phase: phase.id, cycle: state.cycle, role_id: step.role_id}
    artifacts = Enum.reverse(artifacts_from(output)) ++ result.artifacts
    result = %{result | events: [event | result.events], artifacts: artifacts}

    %{context | result: result}
  end

  defp record_failure(%{context: %{result: result} = context, phase: phase} = step, failure) do
    failure_entry = %{
      phase: phase.id,
      role_id: step.role_id,
      attempt: step.attempt,
      kind: failure
    }

    result = %{result | failures: [failure_entry | result.failures]}
    %{step | context: %{context | result: result}}
  end

  defp transition(context, phase, outputs) do
    case phase_transition(context.state, phase, outputs) do
      {:continue, next} ->
        simulate(%{context | state: next})

      {:complete, next} ->
        finish(%{context | state: next})

      {:error, _reason} ->
        context |> fail() |> finish()
    end
  end

  defp phase_transition(state, phase, outputs) do
    if Squad.gate?(phase) do
      gate = Enum.find(outputs, &(&1["kind"] == "gate"))
      SquadFSM.gate(state, Map.put(gate, "role_id", "squad_leader"))
    else
      SquadFSM.next(state)
    end
  end

  defp simulated_output(step) do
    if Squad.gate?(step.phase), do: simulated_gate(step), else: simulated_role_output(step)
  end

  defp simulated_gate(%{context: %{state: state, scenario: scenario}, phase: phase}) do
    rework? = phase.id == scenario.rework_phase and state.cycle < scenario.leader_rework_rounds

    %{
      "kind" => "gate",
      "decision" => if(rework?, do: "rework", else: "approve"),
      "target_phase" => if(rework?, do: phase.rework_phase, else: nil),
      "reasons" => if(rework?, do: ["seeded rework"], else: [])
    }
  end

  defp simulated_role_output(%{phase: phase, role_id: role_id}) do
    role_id
    |> Squad.role()
    |> Map.fetch!(:artifacts)
    |> Enum.filter(&(&1 in phase.artifact_kinds))
    |> Enum.map(&simulated_artifact(&1, phase.id))
    |> artifact_output()
  end

  defp simulated_artifact(artifact_type, phase_id) do
    %{
      "kind" => "artifact",
      "artifact_type" => artifact_type,
      "summary" => "simulated #{phase_id}",
      "blockers" => []
    }
  end

  defp artifact_output([artifact]), do: artifact
  defp artifact_output(artifacts), do: %{"kind" => "artifacts", "artifacts" => artifacts}

  defp artifacts_from(%{"kind" => "artifact"} = output), do: [output]
  defp artifacts_from(%{"kind" => "artifacts", "artifacts" => artifacts}), do: artifacts
  defp artifacts_from(_output), do: []

  defp initial_context(scenario) do
    %{
      state: SquadFSM.new("simulation"),
      scenario: scenario,
      result: %{steps: 0, events: [], artifacts: [], failures: [], max_delay_ms: 0}
    }
  end

  defp fail(%{state: state} = context) do
    %{context | state: %{state | phase_index: Squad.complete_phase_index(), outcome: :failed}}
  end

  defp finish(%{state: state, result: result}) do
    %{
      outcome: SquadFSM.outcome(state),
      state: state,
      steps: result.steps,
      events: Enum.reverse(result.events),
      artifacts: Enum.reverse(result.artifacts),
      failures: Enum.reverse(result.failures),
      max_delay_ms: result.max_delay_ms
    }
  end

  defp step_limit(state) do
    base = length(Squad.phases()) * 2
    base + state.rework_budget * 20
  end
end
