defmodule ReyCode.Orchestration.Squad.Output do
  @moduledoc "Parses and validates provider-independent squad artifact and gate envelopes."

  alias ReyCode.Orchestration.Squad

  @spec parse(map(), map()) :: {:ok, map()} | {:error, atom()}
  def parse(invocation, message) do
    metadata = invocation.completion_metadata || %{}

    with {:ok, output} <- output(metadata, message.body),
         {:ok, output} <- validate(output, invocation.participant.id, invocation[:phase]) do
      {:ok, Map.put(output, "role_id", invocation.participant.id)}
    end
  end

  defp output(%{"squad_output" => output}, _body) when is_map(output), do: {:ok, output}

  defp output(_metadata, body) when is_binary(body) do
    case Jason.decode(String.trim(body)) do
      {:ok, output} when is_map(output) -> {:ok, output}
      _error -> {:error, :invalid_squad_output}
    end
  end

  defp output(_metadata, _body), do: {:error, :invalid_squad_output}

  defp validate(%{"kind" => "artifact"} = output, role_id, _phase) do
    kind = output["artifact_type"]
    blockers = Map.get(output, "blockers", [])

    if is_binary(kind) and is_binary(output["summary"]) and string_list?(blockers) and
         (Squad.eligible?(role_id, :record, kind) or
            Squad.eligible?(role_id, :record_legacy, kind)) do
      {:ok, Map.put(output, "blockers", blockers)}
    else
      {:error, :invalid_artifact}
    end
  end

  defp validate(%{"kind" => "artifacts"} = output, role_id, phase) do
    expected = Squad.required_artifacts(phase, role_id)

    with true <- expected != [],
         {:ok, artifacts} <- artifact_list(output["artifacts"]),
         {:ok, artifacts} <- validate_artifacts(artifacts, role_id),
         true <- exact_bundle?(artifacts, expected) do
      {:ok, Map.put(output, "artifacts", artifacts)}
    else
      _ -> {:error, :invalid_artifact_bundle}
    end
  end

  defp validate(%{"kind" => "gate"} = output, role_id, _phase) do
    decision = output["decision"]
    reasons = Map.get(output, "reasons", [])
    target_phase = Map.get(output, "target_phase", nil)

    if is_binary(decision) and string_list?(reasons) and
         (is_nil(target_phase) or is_binary(target_phase)) and
         Squad.eligible?(role_id, :decide, decision) do
      {:ok, output |> Map.put("reasons", reasons) |> Map.put("target_phase", target_phase)}
    else
      {:error, :invalid_gate}
    end
  end

  defp validate(_output, _role_id, _phase), do: {:error, :invalid_squad_output}

  defp artifact_list(artifacts) when is_list(artifacts), do: {:ok, artifacts}
  defp artifact_list(_artifacts), do: {:error, :invalid_artifact_bundle}

  defp string_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)

  defp validate_artifacts(artifacts, role_id) do
    Enum.reduce_while(artifacts, {:ok, []}, fn
      artifact, {:ok, valid} when is_map(artifact) ->
        case validate(Map.put(artifact, "kind", "artifact"), role_id, nil) do
          {:ok, artifact} -> {:cont, {:ok, [Map.delete(artifact, "kind") | valid]}}
          {:error, _reason} -> {:halt, {:error, :invalid_artifact_bundle}}
        end

      _artifact, _acc ->
        {:halt, {:error, :invalid_artifact_bundle}}
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  # Sorted comparison preserves multiplicities, so duplicate or unexpected
  # kinds fail alongside missing ones.
  defp exact_bundle?(artifacts, expected) do
    Enum.sort(Enum.map(artifacts, & &1["artifact_type"])) == Enum.sort(expected)
  end
end
