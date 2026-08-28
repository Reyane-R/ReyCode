defmodule ReyCode.Orchestration.Projection do
  @moduledoc """
  The durable orchestration read model exposed to the engine and TUI.

  Construction, legacy normalization, and cross-record queries live here so
  callers do not duplicate knowledge of the projection representation.
  """

  @behaviour Access

  alias ReyCode.Orchestration.{Invocation, Message, Session, Turn}

  @fields [:sequence, :sessions, :session_order, :messages, :turns, :invocations]

  defstruct sequence: 0,
            sessions: %{},
            session_order: [],
            messages: %{},
            turns: %{},
            invocations: %{}

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          sessions: %{optional(String.t()) => Session.t()},
          session_order: [String.t()],
          messages: %{optional(String.t()) => Message.t()},
          turns: %{optional(String.t()) => Turn.t()},
          invocations: %{optional(String.t()) => Invocation.t()}
        }

  @doc "Converts a decoded or legacy projection map into the current typed records."
  @spec from_map(t() | map()) :: t()
  def from_map(projection) when is_map(projection) do
    projection = normalize_legacy_keys(projection)
    projection = struct!(__MODULE__, Map.take(projection, @fields))

    %{
      projection
      | sessions: normalize_records(projection.sessions, &Session.from_map/1),
        messages: normalize_records(projection.messages, &Message.from_map/1),
        turns: normalize_records(projection.turns, &Turn.from_map/1),
        invocations: normalize_records(projection.invocations, &Invocation.from_map/1)
    }
  end

  defp normalize_legacy_keys(projection) do
    {legacy_sessions, projection} = Map.pop(projection, :rooms)
    {legacy_order, projection} = Map.pop(projection, :room_order)

    projection
    |> put_legacy(:sessions, legacy_sessions)
    |> put_legacy(:session_order, legacy_order)
  end

  defp put_legacy(map, _key, nil), do: map
  defp put_legacy(map, key, value), do: Map.put_new(map, key, value)

  @doc "Returns the invocation awaiting a tool decision in a turn, if any."
  @spec pending_tool_invocation(t(), String.t() | nil) :: Invocation.t() | nil
  def pending_tool_invocation(_projection, nil), do: nil

  def pending_tool_invocation(projection, turn_id) do
    projection.invocations
    |> Map.values()
    |> Enum.find(fn invocation ->
      review = invocation.pending_tool_review
      invocation.turn_id == turn_id and not is_nil(review) and Map.get(review, :tool) != "merge"
    end)
  end

  @doc "Returns delegated child Invocations represented in one Session's message order."
  @spec delegated_invocations(t(), String.t()) :: [Invocation.t()]
  def delegated_invocations(projection, session_id) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        []

      session ->
        session.message_order
        |> Enum.map(&projection.messages[&1])
        |> Enum.filter(&(&1 && &1.invocation_id))
        |> Enum.map(&projection.invocations[&1.invocation_id])
        |> Enum.filter(&(&1 && &1.delegated_from_invocation_id != nil))
        |> Enum.uniq_by(& &1.id)
    end
  end

  @doc "Returns the newest Invocation awaiting an OperatorQuestion in one Session."
  @spec pending_question_invocation(t(), String.t()) :: Invocation.t() | nil
  def pending_question_invocation(projection, session_id) do
    session_invocations(projection, session_id)
    |> Enum.find(&(not is_nil(Map.get(&1, :coordination) && &1.coordination.pending_question)))
  end

  @doc "Returns the newest Invocation with a WorkPlan in one Session."
  @spec work_plan_invocation(t(), String.t()) :: Invocation.t() | nil
  def work_plan_invocation(projection, session_id) do
    session_invocations(projection, session_id)
    |> Enum.find(&(not is_nil(Map.get(&1, :coordination) && &1.coordination.work_plan)))
  end

  defp session_invocations(projection, session_id) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        []

      session ->
        session.message_order
        |> Enum.map(&projection.messages[&1])
        |> Enum.filter(&(&1 && &1.invocation_id))
        |> Enum.map(&projection.invocations[&1.invocation_id])
        |> Enum.filter(& &1)
    end
  end

  @impl Access
  def fetch(projection, key), do: Map.fetch(projection, key)

  @impl Access
  def get_and_update(projection, key, fun) do
    current = Map.fetch!(projection, key)

    case fun.(current) do
      :pop -> {current, Map.put(projection, key, nil)}
      {get, update} -> {get, Map.put(projection, key, update)}
    end
  end

  @impl Access
  def pop(projection, key) do
    current = Map.fetch!(projection, key)
    {current, Map.put(projection, key, nil)}
  end

  defp normalize_records(records, convert) do
    Map.new(records || %{}, fn {id, record} -> {id, convert.(record)} end)
  end
end
