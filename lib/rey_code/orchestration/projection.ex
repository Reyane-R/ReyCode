defmodule ReyCode.Orchestration.Projection do
  @moduledoc """
  The durable orchestration read model exposed to the engine and TUI.

  Construction and cross-record queries live here so callers do not duplicate
  knowledge of the projection's top-level representation.
  """

  @behaviour Access

  defstruct sequence: 0,
            rooms: %{},
            room_order: [],
            messages: %{},
            turns: %{},
            invocations: %{}

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          rooms: map(),
          room_order: [String.t()],
          messages: map(),
          turns: map(),
          invocations: map()
        }

  @doc "Converts a legacy map projection into the current explicit record."
  @spec from_map(map()) :: t()
  def from_map(%__MODULE__{} = projection), do: projection

  def from_map(projection) when is_map(projection) do
    fields = Map.keys(%__MODULE__{}) -- [:__struct__]
    struct!(__MODULE__, Map.take(projection, fields))
  end

  @doc "Returns the invocation awaiting a tool decision in a turn, if any."
  @spec pending_tool_invocation(t(), String.t() | nil) :: map() | nil
  def pending_tool_invocation(_projection, nil), do: nil

  def pending_tool_invocation(projection, turn_id) do
    projection.invocations
    |> Map.values()
    |> Enum.find(fn invocation ->
      invocation.turn_id == turn_id and not is_nil(invocation.pending_tool_review)
    end)
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
end
