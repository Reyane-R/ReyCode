defmodule ReyCode.Orchestration.Participant do
  @moduledoc "A configured room participant or squad role in the orchestration projection."

  @fields [:id, :name, :perspective, :provider, :model, :kind]

  defstruct id: nil,
            name: nil,
            perspective: nil,
            provider: nil,
            model: nil,
            kind: :legacy

  @type kind :: :primary | :task | :legacy
  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          perspective: String.t() | nil,
          provider: atom() | String.t() | nil,
          model: String.t() | nil,
          kind: kind()
        }

  @doc "Converts a decoded or legacy participant map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(participant) when is_map(participant) do
    participant = Map.put(participant, :kind, kind(Map.get(participant, :kind)))
    struct!(__MODULE__, Map.take(participant, @fields))
  end

  defp kind(:primary), do: :primary
  defp kind("primary"), do: :primary
  defp kind(:task), do: :task
  defp kind("task"), do: :task
  defp kind(_kind), do: :legacy
end
