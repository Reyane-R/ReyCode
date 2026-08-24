defmodule ReyCode.Orchestration.Squad.Phase do
  @moduledoc "Stable named state in the ordered squad workflow."

  @fields [:id, :role_ids, :artifact_kinds, :gate?, :rework_phase]

  defstruct id: nil, role_ids: [], artifact_kinds: [], gate?: false, rework_phase: nil

  @type t :: %__MODULE__{
          id: String.t(),
          role_ids: [String.t()],
          artifact_kinds: [String.t()],
          gate?: boolean(),
          rework_phase: String.t() | nil
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = phase), do: phase

  def from_map(phase) when is_map(phase) do
    phase =
      phase
      |> Map.put_new(:role_ids, Map.get(phase, :roles, []))
      |> Map.put_new(:artifact_kinds, Map.get(phase, :artifacts, []))
      |> Map.put_new(:gate?, Map.get(phase, :gate, false))
      |> Map.put_new(:rework_phase, Map.get(phase, :rework_to))

    struct!(__MODULE__, Map.take(phase, @fields))
  end
end
