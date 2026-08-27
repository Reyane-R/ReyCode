defmodule ReyCode.Orchestration.ProviderRound do
  @moduledoc "One normalized provider response retained by an Invocation."

  alias ReyCode.Orchestration.Steering
  alias ReyCode.Provider.ToolCall

  @fields [:index, :text, :tool_calls, :steering, :usage]

  defstruct index: 0, text: "", tool_calls: [], steering: [], usage: nil

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          text: String.t(),
          tool_calls: [ToolCall.t()],
          steering: [Steering.t()],
          usage: map() | nil
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = round), do: round

  def from_map(round) when is_map(round) do
    round = struct!(__MODULE__, Map.take(round, @fields))

    %{
      round
      | tool_calls: Enum.map(round.tool_calls || [], &normalize_call/1),
        steering: Enum.map(round.steering || [], &Steering.from_map/1)
    }
  end

  defp normalize_call(%ToolCall{} = call), do: call

  defp normalize_call(%{id: id, tool: tool, arguments: arguments}),
    do: ToolCall.new(id, tool, arguments)

  defp normalize_call(call) do
    case ToolCall.from_wire(call) do
      {:ok, call} -> call
      {:error, :invalid_tool_call} -> raise ArgumentError, "invalid projected tool call"
    end
  end
end
