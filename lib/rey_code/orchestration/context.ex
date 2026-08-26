defmodule ReyCode.Orchestration.Context do
  @moduledoc """
  Selects the durable message context visible to a provider round.

  Room messages are followed by the invocation's recorded provider rounds:
  each round contributes its assistant message (text plus tool calls) and one
  tool-result message per terminal tool run, so continuation never depends on
  provider-local state.
  """

  alias ReyCode.Orchestration.{Invocation, Projection, Room, ToolRuns, Turn}
  alias ReyCode.Provider.{Message, ToolCall}

  @spec messages(Room.t(), Turn.t(), Invocation.t(), Projection.t()) :: [Message.t()]
  def messages(room, turn, invocation, projection) do
    room_messages(room, turn, invocation, projection) ++ round_messages(invocation)
  end

  @spec include?(
          ReyCode.Orchestration.Message.t(),
          Turn.t(),
          Invocation.t(),
          Projection.t()
        ) :: boolean()
  # A delegation child receives its self-contained brief through the system
  # prompt. The current parent user message often says "delegate to <name>";
  # exposing it again makes the child repeat spawn_task and hit the depth
  # guard instead of doing the delegated work. Earlier completed room history
  # remains visible.
  def include?(message, turn, %{delegated_from_invocation_id: parent_id}, _projection)
      when not is_nil(parent_id) do
    message.created_sequence < turn.context_through_sequence and message.status == :completed
  end

  def include?(message, %{mode: :debate} = turn, invocation, projection) do
    stage_visible?(message, turn, invocation, projection)
  end

  def include?(message, %{mode: :squad} = turn, invocation, projection) do
    cond do
      message.status != :completed ->
        false

      message.turn_id != turn.id or message.invocation_id == nil ->
        message.created_sequence <= turn.context_through_sequence

      true ->
        message.invocation_id in invocation.dependencies and
          projection.invocations[message.invocation_id].status == :completed
    end
  end

  def include?(message, turn, _invocation, _projection) do
    message.created_sequence <= turn.context_through_sequence and message.status == :completed
  end

  defp room_messages(room, turn, invocation, projection) do
    room.message_order
    |> Enum.reverse()
    |> Enum.map(&projection.messages[&1])
    |> Enum.filter(&include?(&1, turn, invocation, projection))
    |> Enum.map(&Message.new(role: &1.role, content: &1.body, author: &1.author))
  end

  defp round_messages(invocation) do
    Enum.flat_map(invocation.rounds, &round_message(invocation, &1))
  end

  defp round_message(invocation, round) do
    calls = Enum.map(round.tool_calls || [], &call/1)

    assistant =
      Message.new(
        role: :assistant,
        content: round.text,
        tool_calls: calls
      )

    results =
      calls
      |> Enum.flat_map(fn call ->
        case ToolRuns.run_for_call(invocation, call.id) do
          nil ->
            []

          run ->
            [
              Message.new(
                role: :tool,
                content: ToolRuns.result_content(run),
                tool_call_id: call.id,
                name: call.tool
              )
            ]
        end
      end)

    [assistant | results]
  end

  defp call(%{"id" => id, "tool" => tool, "arguments" => arguments}),
    do: ToolCall.new(id, tool, arguments)

  defp call(%{__struct__: ToolCall} = call), do: call

  defp stage_visible?(message, turn, invocation, projection) do
    cond do
      message.status != :completed ->
        false

      message.turn_id != turn.id or message.invocation_id == nil ->
        message.created_sequence <= turn.context_through_sequence

      true ->
        projection.invocations[message.invocation_id].phase_index < invocation.phase_index
    end
  end
end
