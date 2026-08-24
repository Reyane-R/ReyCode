defmodule ReyCode.Orchestration.Turn do
  @moduledoc "A durable orchestration turn in the projection."

  @fields [
    :id,
    :room_id,
    :user_message_id,
    :mode,
    :status,
    :context_through_sequence,
    :invocation_order,
    :outcome,
    :squad,
    :created_at
  ]

  defstruct id: nil,
            room_id: nil,
            user_message_id: nil,
            mode: nil,
            status: nil,
            context_through_sequence: 0,
            invocation_order: [],
            outcome: nil,
            squad: nil,
            created_at: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          room_id: String.t() | nil,
          user_message_id: String.t() | nil,
          mode: atom() | nil,
          status: atom() | nil,
          context_through_sequence: non_neg_integer(),
          invocation_order: [String.t()],
          outcome: atom() | nil,
          squad: map() | nil,
          created_at: term()
        }

  @doc "Converts a decoded or legacy turn map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(turn) when is_map(turn) do
    struct!(__MODULE__, Map.take(turn, @fields))
  end
end
