defmodule ReyCode.Orchestration.Squad.Artifact do
  @moduledoc "A recorded squad role deliverable in the orchestration projection."

  @enforce_keys [
    :role_id,
    :kind,
    :phase,
    :cycle,
    :invocation_id,
    :message_id,
    :summary,
    :blockers,
    :digest
  ]
  defstruct [
    :role_id,
    :kind,
    :phase,
    :cycle,
    :invocation_id,
    :message_id,
    :summary,
    :blockers,
    :digest
  ]

  @type t :: %__MODULE__{
          role_id: String.t(),
          kind: String.t(),
          phase: String.t(),
          cycle: non_neg_integer(),
          invocation_id: String.t() | nil,
          message_id: String.t() | nil,
          summary: String.t(),
          blockers: [String.t()],
          digest: String.t() | nil
        }

  @doc "Converts a legacy or decoded artifact map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = artifact), do: artifact

  def from_map(artifact) when is_map(artifact) do
    %__MODULE__{
      role_id: fetch(artifact, :role_id) || fetch(artifact, :seat_id),
      kind: fetch(artifact, :kind),
      phase: fetch(artifact, :phase),
      cycle: fetch(artifact, :cycle, 0),
      invocation_id: fetch(artifact, :invocation_id),
      message_id: fetch(artifact, :message_id),
      summary: fetch(artifact, :summary, ""),
      blockers: fetch(artifact, :blockers, []),
      digest: fetch(artifact, :digest)
    }
  end

  defp fetch(artifact, key, default \\ nil) when is_atom(key) do
    case Map.fetch(artifact, key) do
      {:ok, value} -> value
      :error -> Map.get(artifact, Atom.to_string(key), default)
    end
  end
end
