defmodule ReyCode.Orchestration.PeerMessage do
  @moduledoc "A bounded durable message delivered between children in one DelegationWave."

  @fields [
    :id,
    :sender_invocation_id,
    :sender_name,
    :target_invocation_id,
    :body,
    :created_sequence
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          id: String.t(),
          sender_invocation_id: String.t(),
          sender_name: String.t(),
          target_invocation_id: String.t(),
          body: String.t(),
          created_sequence: pos_integer()
        }

  @doc "Converts a decoded peer-message map into the typed record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = message), do: message
  def from_map(message) when is_map(message), do: struct!(__MODULE__, Map.take(message, @fields))
end
