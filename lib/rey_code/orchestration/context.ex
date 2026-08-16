defmodule ReyCode.Orchestration.Context do
  @moduledoc "Selects the durable message context visible to a provider invocation."

  @spec messages(map(), map(), map(), map()) :: [map()]
  def messages(room, turn, invocation, projection) do
    room.message_order
    |> Enum.reverse()
    |> Enum.map(&projection.messages[&1])
    |> Enum.filter(&include?(&1, turn, invocation, projection))
    |> Enum.map(&%{role: &1.role, content: &1.body, author: &1.author})
  end

  @spec include?(map(), map(), map(), map()) :: boolean()
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

  defp stage_visible?(message, turn, invocation, projection) do
    cond do
      message.status != :completed ->
        false

      message.turn_id != turn.id or message.invocation_id == nil ->
        message.created_sequence <= turn.context_through_sequence

      true ->
        projection.invocations[message.invocation_id].stage < invocation.stage
    end
  end
end
