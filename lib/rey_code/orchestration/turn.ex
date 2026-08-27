defmodule ReyCode.Orchestration.Turn do
  @moduledoc "A durable orchestration turn with distinct lifecycle status and terminal outcome."

  alias ReyCode.Orchestration.SquadRun

  @fields [
    :id,
    :room_id,
    :user_message_id,
    :input_kind,
    :mode,
    :participant_id,
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
            input_kind: :operator,
            mode: nil,
            participant_id: nil,
            status: nil,
            context_through_sequence: 0,
            invocation_order: [],
            outcome: nil,
            squad: nil,
            created_at: nil

  @type status :: :queued | :running | :terminal
  @type outcome :: :completed | :partial | :failed | :cancelled | :reworked
  @type t :: %__MODULE__{
          id: String.t() | nil,
          room_id: String.t() | nil,
          user_message_id: String.t() | nil,
          input_kind: :operator | :follow_up,
          participant_id: String.t() | nil,
          mode: atom() | nil,
          status: status() | nil,
          context_through_sequence: non_neg_integer(),
          invocation_order: [String.t()],
          outcome: outcome() | nil,
          squad: SquadRun.t() | nil,
          created_at: term()
        }

  @doc "Converts a decoded or legacy turn map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(turn) when is_map(turn) do
    turn = normalize_legacy(turn)
    turn = struct!(__MODULE__, Map.take(turn, @fields))
    %{turn | squad: optional_squad(turn.squad)}
  end

  defp normalize_legacy(%{status: status} = turn)
       when status in [:completed, :partial, :failed, :cancelled, :reworked] do
    turn
    |> Map.put(:status, :terminal)
    |> Map.put_new(:outcome, status)
  end

  defp normalize_legacy(turn), do: turn

  defp optional_squad(nil), do: nil
  defp optional_squad(squad), do: SquadRun.from_map(squad)
end
