defmodule ReyCode.Orchestration.Squad.Role do
  @moduledoc "Stable responsibility definition in the squad workflow."

  @fields [:id, :name, :perspective, :artifacts, :decisions]

  defstruct id: nil, name: nil, perspective: nil, artifacts: [], decisions: []

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          perspective: String.t(),
          artifacts: [String.t()],
          decisions: [String.t()]
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = role), do: role
  def from_map(role) when is_map(role), do: struct!(__MODULE__, Map.take(role, @fields))
end
