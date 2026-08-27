defmodule ReyCode.Orchestration.Workflow.Squad.Finalizer do
  @moduledoc false

  alias ReyCode.{Failure, Hashing, JSON, Retry}
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
        error =
          Failure.new(
            :invalid_squad_output,
            "Squad role returned invalid structured output: #{reason}",
            true
          )

        failure_action(invocation, error)
    end
  end

  def finalize(invocation, _message, {:failed, error}, _opts) do
    failure_action(invocation, error)
  end

  defp failure_action(invocation, error) do
    failed_entry = EventEntries.invocation_terminal(invocation, {:failed, error})

    if Retry.retryable?(error) and invocation.attempt < Squad.retry_limit() do
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
    type =
      if invocation.phase == "release_gate" and Keyword.fetch!(opts, :human_release_review?),
        do: :gate_review_requested,
        else: :squad_decision_recorded

    [EventEntries.squad_gate(invocation, output, type)]
  end

  defp artifact_entry(invocation, output, message) do
    EventEntries.squad_artifact(
      invocation,
      output,
      Hashing.sha256_hex(message.body)
    )
  end

  defp retry_spec(invocation) do
    %{
      participant_id: invocation.participant.id,
      participant: invocation.participant,
      phase_index: invocation.phase_index,
      phase: invocation.phase,
      cycle: invocation.cycle,
      logical_work_id: invocation.logical_work_id,
      dependencies: invocation.dependencies,
      attempt: invocation.attempt + 1,
      label: invocation.label,
      system_prompt: invocation.system_prompt,
      project_instructions: instruction_content(invocation),
      project_instruction_digest: instruction_digest(invocation),
      project_instruction_sources: instruction_sources(invocation)
    }
  end

  defp instruction_content(invocation), do: instruction_field(invocation, :content, "")
  defp instruction_digest(invocation), do: instruction_field(invocation, :digest, nil)
  defp instruction_sources(invocation), do: instruction_field(invocation, :sources, [])

  defp instruction_field(invocation, field, default) do
    case Map.get(invocation, :project_instructions) do
      nil -> default
      capture -> Map.get(capture, field, default)
    end
  end
end
