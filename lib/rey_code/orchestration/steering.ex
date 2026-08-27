defmodule ReyCode.Orchestration.Steering do
  @moduledoc "One durable Operator correction consumed at a provider-round boundary."

  @enforce_keys [:id, :body, :requested_sequence]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          body: String.t(),
          requested_sequence: non_neg_integer()
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = steering), do: steering

  def from_map(steering) when is_map(steering) do
    %__MODULE__{
      id: fetch(steering, :id),
      body: fetch(steering, :body),
      requested_sequence: fetch(steering, :requested_sequence, 0)
    }
  end

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = steering) do
    %{
      "id" => steering.id,
      "body" => steering.body,
      "requested_sequence" => steering.requested_sequence
    }
  end

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
