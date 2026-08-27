defmodule ReyCode.Orchestration.Projection do
  @moduledoc """
  The durable orchestration read model exposed to the engine and TUI.

  Construction, legacy normalization, and cross-record queries live here so
  callers do not duplicate knowledge of the projection representation.
  """

  @behaviour Access

  alias ReyCode.Orchestration.{Invocation, Message, Room, Turn}

  @fields [:sequence, :rooms, :room_order, :messages, :turns, :invocations]

  defstruct sequence: 0,
            rooms: %{},
            room_order: [],
            messages: %{},
            turns: %{},
            invocations: %{}

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          rooms: %{optional(String.t()) => Room.t()},
          room_order: [String.t()],
          messages: %{optional(String.t()) => Message.t()},
          turns: %{optional(String.t()) => Turn.t()},
          invocations: %{optional(String.t()) => Invocation.t()}
        }

  @doc "Converts a decoded or legacy projection map into the current typed records."
  @spec from_map(t() | map()) :: t()
  def from_map(projection) when is_map(projection) do
    projection = struct!(__MODULE__, Map.take(projection, @fields))

    %{
      projection
      | rooms: normalize_records(projection.rooms, &Room.from_map/1),
        messages: normalize_records(projection.messages, &Message.from_map/1),
        turns: normalize_records(projection.turns, &Turn.from_map/1),
        invocations: normalize_records(projection.invocations, &Invocation.from_map/1)
    }
  end

  @doc "Returns the invocation awaiting a tool decision in a turn, if any."
  @spec pending_tool_invocation(t(), String.t() | nil) :: Invocation.t() | nil
  def pending_tool_invocation(_projection, nil), do: nil

  def pending_tool_invocation(projection, turn_id) do
    projection.invocations
    |> Map.values()
    |> Enum.find(fn invocation ->
      invocation.turn_id == turn_id and not is_nil(invocation.pending_tool_review)
    end)
  end

  @doc "Returns delegated child Invocations represented in one Session's message order."
  @spec delegated_invocations(t(), String.t()) :: [Invocation.t()]
  def delegated_invocations(projection, room_id) do
    case Map.get(projection.rooms, room_id) do
      nil ->
        []

      room ->
        room.message_order
        |> Enum.map(&projection.messages[&1])
        |> Enum.filter(&(&1 && &1.invocation_id))
        |> Enum.map(&projection.invocations[&1.invocation_id])
        |> Enum.filter(&(&1 && &1.delegated_from_invocation_id != nil))
        |> Enum.uniq_by(& &1.id)
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
