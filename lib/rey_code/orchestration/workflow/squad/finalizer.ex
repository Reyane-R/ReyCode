defmodule ReyCode.Orchestration.Workflow.Squad.Finalizer do
  @moduledoc false

  alias ReyCode.{Hashing, JSON}
  alias ReyCode.Orchestration.{EventEntries, Squad}
  alias ReyCode.Orchestration.Squad.Output

  def finalize(invocation, message, {:completed, metadata}, opts) do
    metadata = JSON.normalize(metadata)
    completed = %{invocation | completion_metadata: metadata, status: :completed}

    case Output.parse(completed, message) do
      {:ok, output} ->
        entries =
          [EventEntries.invocation_terminal(invocation, {:completed, metadata})] ++
            output_entries(invocation, output, message, opts)

        {:advance, entries}

      {:error, reason} ->
        error = %{
          "category" => "invalid_squad_output",
          "message" => "Squad role returned invalid structured output: #{reason}",
          "retryable" => true
        }

        failure_action(invocation, error)
    end
  end

  def finalize(invocation, _message, {:failed, error}, _opts) do
    failure_action(invocation, error)
  end

  defp failure_action(invocation, error) do
    failed_entry = EventEntries.invocation_terminal(invocation, {:failed, error})

    if invocation.attempt < Squad.retry_limit() do
      entries = [failed_entry, EventEntries.squad_provider_retry(invocation, error)]
      {:retry, entries, retry_spec(invocation)}
    else
      {:advance, [failed_entry]}
    end
  end

  defp output_entries(invocation, %{"kind" => "artifacts"} = output, message, _opts) do
    Enum.map(output["artifacts"], &artifact_entry(invocation, &1, message))
  end

  defp output_entries(invocation, %{"kind" => "artifact"} = output, message, _opts) do
    [artifact_entry(invocation, output, message)]
  end

  defp output_entries(invocation, %{"kind" => "gate"} = output, _message, opts) do
    data = %{
      "turn_id" => invocation.turn_id,
      "room_id" => invocation.room_id,
      "seat_id" => invocation.participant.id,
      "decision" => output["decision"],
      "phase" => invocation.phase,
      "cycle" => invocation.cycle,
      "target_phase" => output["target_phase"],
      "reasons" => output["reasons"]
    }

    type =
      if invocation.phase == "release_gate" and Keyword.fetch!(opts, :human_release_review?),
        do: :gate_review_requested,
        else: :squad_decision_recorded

    [{type, data, turn_metadata(invocation)}]
  end

  defp artifact_entry(invocation, output, message) do
    data = %{
      "turn_id" => invocation.turn_id,
      "room_id" => invocation.room_id,
      "seat_id" => invocation.participant.id,
      "kind" => output["artifact_type"],
      "phase" => invocation.phase,
      "cycle" => invocation.cycle,
      "invocation_id" => invocation.id,
      "message_id" => invocation.message_id,
      "summary" => output["summary"],
      "blockers" => output["blockers"],
      "digest" => Hashing.sha256_hex(message.body)
    }

    {:squad_artifact_recorded, data, turn_metadata(invocation)}
  end

  defp turn_metadata(invocation) do
    EventEntries.aggregate_metadata(
      :turn,
      invocation.turn_id,
      invocation.room_id,
      invocation.turn_id
    )
  end

  defp retry_spec(invocation) do
    %{
      participant_id: invocation.participant.id,
      participant: invocation.participant,
      stage: invocation.stage,
      phase: invocation.phase,
      cycle: invocation.cycle,
      logical_work_id: invocation.logical_work_id,
      dependencies: invocation.dependencies,
      attempt: invocation.attempt + 1,
      label: invocation.label,
      system_prompt: invocation.system_prompt
    }
  end
end
