defmodule ReyCode.Orchestration.Squad.Seat do
  @moduledoc "Session-specific provider/model assignment for one squad Role."

  @fields [:id, :role_id, :name, :perspective, :provider, :model]

  defstruct id: nil, role_id: nil, name: nil, perspective: nil, provider: nil, model: nil

  @type t :: %__MODULE__{
          id: String.t(),
          role_id: String.t(),
          name: String.t(),
          perspective: String.t(),
          provider: atom() | String.t() | nil,
          model: String.t() | nil
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = seat), do: seat

  def from_map(seat) when is_map(seat) do
    seat = Map.put_new(seat, :role_id, Map.get(seat, :id))
    struct!(__MODULE__, Map.take(seat, @fields))
  end
end
