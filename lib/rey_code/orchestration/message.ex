defmodule ReyCode.Orchestration.Message do
  @moduledoc "A durable user or assistant message in the orchestration projection."

  alias ReyCode.Failure

  @fields [
    :id,
    :room_id,
    :turn_id,
    :invocation_id,
    :author,
    :role,
    :status,
    :body,
    :created_at,
    :created_sequence,
    :error
  ]

  defstruct id: nil,
            room_id: nil,
            turn_id: nil,
            invocation_id: nil,
            author: nil,
            role: nil,
            status: nil,
            body: "",
            created_at: nil,
            created_sequence: 0,
            error: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          room_id: String.t() | nil,
          turn_id: String.t() | nil,
          invocation_id: String.t() | nil,
          author: map() | nil,
          role: atom() | nil,
          status: atom() | nil,
          body: String.t(),
          created_at: term(),
          created_sequence: non_neg_integer(),
          error: Failure.t() | nil
        }

  @doc "Converts a decoded or legacy message map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(message) when is_map(message) do
    message = struct!(__MODULE__, Map.take(message, @fields))
    %{message | error: optional_failure(message.error)}
  end

  defp optional_failure(nil), do: nil
  defp optional_failure(value), do: Failure.from_map(value)
end
