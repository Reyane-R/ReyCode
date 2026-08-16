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

  defp validate(%{"kind" => "artifact"} = output, role_id, _phase) do
    kind = output["artifact_type"]
    blockers = Map.get(output, "blockers", [])

    if is_binary(kind) and is_binary(output["summary"]) and is_list(blockers) and
         (Squad.eligible?(role_id, :record, kind) or
            Squad.eligible?(role_id, :record_legacy, kind)) do
      {:ok, Map.put(output, "blockers", blockers)}
    else
      {:error, :invalid_artifact}
    end
  end

  defp validate(%{"kind" => "artifacts", "artifacts" => artifacts} = output, role_id, phase)
       when is_list(artifacts) do
    expected = Squad.required_artifacts(phase, role_id)

    with true <- expected != [],
         {:ok, artifacts} <- validate_artifacts(artifacts, role_id),
         true <- MapSet.new(artifacts, & &1["artifact_type"]) == MapSet.new(expected) do
      {:ok, Map.put(output, "artifacts", artifacts)}
    else
      _ -> {:error, :invalid_artifact_bundle}
    end
  end

  defp validate(%{"kind" => "gate"} = output, role_id, _phase) do
    decision = output["decision"]
    reasons = Map.get(output, "reasons", [])

    if is_list(reasons) and Squad.eligible?(role_id, :decide, decision) do
      {:ok, output |> Map.put("reasons", reasons) |> Map.put_new("target_phase", nil)}
    else
      {:error, :invalid_gate}
    end
  end

  defp validate(_output, _role_id, _phase), do: {:error, :invalid_squad_output}

  defp validate_artifacts(artifacts, role_id) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, valid} ->
      case validate(Map.put(artifact, "kind", "artifact"), role_id, nil) do
        {:ok, artifact} -> {:cont, {:ok, [Map.delete(artifact, "kind") | valid]}}
        {:error, _reason} -> {:halt, {:error, :invalid_artifact_bundle}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end
end
