defmodule ReyCode.Orchestration.Turn do
  @moduledoc "A durable orchestration turn with distinct lifecycle status and terminal outcome."

  alias ReyCode.Orchestration.{SquadRun, StrategicReview}

  @fields [
    :id,
    :session_id,
    :user_message_id,
    :input_kind,
    :mode,
    :participant_id,
    :source_invocation_id,
    :task,
    :retry_of_turn_id,
    :strategy_review,
    :detached?,
    :status,
    :context_through_sequence,
    :invocation_order,
    :outcome,
    :squad,
    :created_at,
    :started_at,
    :completed_at
  ]

  defstruct id: nil,
            session_id: nil,
            user_message_id: nil,
            input_kind: :operator,
            mode: nil,
            participant_id: nil,
            source_invocation_id: nil,
            retry_of_turn_id: nil,
            strategy_review: nil,
            task: nil,
            detached?: false,
            status: nil,
            context_through_sequence: 0,
            invocation_order: [],
            outcome: nil,
            squad: nil,
            created_at: nil,
            started_at: nil,
            completed_at: nil

  @type status :: :queued | :running | :terminal
  @type outcome :: :completed | :partial | :failed | :cancelled | :reworked
  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          user_message_id: String.t() | nil,
          input_kind: :operator | :follow_up | :detached,
          participant_id: String.t() | nil,
          mode: atom() | nil,
          source_invocation_id: String.t() | nil,
          retry_of_turn_id: String.t() | nil,
          strategy_review: StrategicReview.t() | nil,
          task: String.t() | nil,
          detached?: boolean(),
          status: status() | nil,
          context_through_sequence: non_neg_integer(),
          invocation_order: [String.t()],
          outcome: outcome() | nil,
          squad: SquadRun.t() | nil,
          created_at: term(),
          started_at: String.t() | nil,
          completed_at: String.t() | nil
        }

  @doc "Converts a decoded or legacy turn map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(turn) when is_map(turn) do
    turn = normalize_legacy(turn)
    turn = struct!(__MODULE__, Map.take(turn, @fields))

    %{
      turn
      | squad: optional_squad(turn.squad),
        strategy_review: strategy_review(turn.strategy_review)
    }
  end

  @doc "Restores an optional frozen review; malformed durable packets fail closed."
  @spec strategy_review(term()) :: StrategicReview.t() | nil
  def strategy_review(nil), do: nil
  def strategy_review(packet), do: StrategicReview.from_map(packet)

  @doc "Checks the frozen packet's owning Session and maximum visible event sequence."
  @spec strategy_review_bound?(StrategicReview.t(), String.t(), non_neg_integer()) :: boolean()
  def strategy_review_bound?(packet, session_id, context_sequence) do
    packet.session_id == session_id and is_integer(context_sequence) and
      packet.projection_sequence <= context_sequence
  end

  @doc "Asserts a restored review belongs to its enclosing Session; old ordinary Turns are unchanged."
  @spec validate_strategy_review!(t(), map() | nil) :: t()
  def validate_strategy_review!(%__MODULE__{strategy_review: nil} = turn, _session), do: turn

  def validate_strategy_review!(%__MODULE__{} = turn, session) do
    packet = turn.strategy_review

    if is_map(session) and turn.mode == :delegate and is_binary(turn.participant_id) and
         strategy_review_bound?(packet, turn.session_id, turn.context_through_sequence) and
         packet.session_id == Map.get(session, :id) and
         packet.workspace == Map.get(session, :workspace) do
      turn
    else
      raise ArgumentError, "strategic review packet does not match its Turn and Session"
    end
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
