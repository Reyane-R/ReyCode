defmodule ReyCode.Orchestration.Author do
  @moduledoc "Message attribution recorded in the orchestration projection."

  alias ReyCode.Orchestration.Participant
  alias ReyCode.Orchestration.Squad.Seat

  @enforce_keys [:kind, :id, :name]
  defstruct [:kind, :id, :name]

  @type kind :: :user | :agent
  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t(),
          name: String.t()
        }

  @spec user(String.t() | nil) :: t()
  def user(name), do: %__MODULE__{kind: :user, id: "user", name: name || "You"}

  @spec from_participant(Participant.t() | Seat.t()) :: t()
  def from_participant(participant),
    do: %__MODULE__{kind: :agent, id: participant.id, name: participant.name}

  @doc "Converts a legacy or decoded author map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = author), do: author

  def from_map(author) when is_map(author) do
    %__MODULE__{
      kind: kind(author[:id] || Map.get(author, "id"), author[:kind] || Map.get(author, "kind")),
      id: author[:id] || Map.get(author, "id", ""),
      name: author[:name] || Map.get(author, "name", "")
    }
  end

  # Legacy snapshots attributed agents by their builder/critic ids before
  # the kind field existed.
  defp kind(_id, kind) when kind in [:agent, "agent"], do: :agent
  defp kind(id, _kind) when id in ["builder", "critic"], do: :agent
  defp kind(_id, _kind), do: :user
end
