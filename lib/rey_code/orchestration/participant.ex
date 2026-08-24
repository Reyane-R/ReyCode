defmodule ReyCode.Orchestration.Participant do
  @moduledoc "A configured room participant or squad role in the orchestration projection."

  @fields [:id, :name, :perspective, :provider, :model]

  defstruct id: nil,
            name: nil,
            perspective: nil,
            provider: nil,
            model: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          perspective: String.t() | nil,
          provider: atom() | String.t() | nil,
          model: String.t() | nil
        }

  @doc "Converts a decoded or legacy participant map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(participant) when is_map(participant) do
    struct!(__MODULE__, Map.take(participant, @fields))
  end
end
