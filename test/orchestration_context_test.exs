defmodule ReyCode.Orchestration.ContextTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Context

  test "debate includes completed earlier stages but excludes same-stage siblings" do
    turn = %{id: "turn-1", mode: :debate, context_through_sequence: 2}
    invocation = %{stage: 1}
    projection = %{invocations: %{"inv-proposal" => %{stage: 0}, "inv-sibling" => %{stage: 1}}}

    historical = message("historical", "turn-0", 1, :completed)
    user_request = message("request", "turn-1", 2, :completed)
    proposal = message("proposal", "turn-1", 5, :completed, "inv-proposal")
    sibling = message("sibling", "turn-1", 6, :completed, "inv-sibling")
    future_request = message("future", "turn-2", 6, :completed)
    streaming_proposal = message("partial", "turn-1", 7, :streaming, "inv-proposal")

    assert Context.include?(historical, turn, invocation, projection)
    assert Context.include?(user_request, turn, invocation, projection)
    assert Context.include?(proposal, turn, invocation, projection)
    refute Context.include?(sibling, turn, invocation, projection)
    refute Context.include?(future_request, turn, invocation, projection)
    refute Context.include?(streaming_proposal, turn, invocation, projection)
  end

  defp message(body, turn_id, sequence, status, invocation_id \\ nil) do
    %{
      body: body,
      turn_id: turn_id,
      invocation_id: invocation_id,
      created_sequence: sequence,
      status: status,
      role: :assistant,
      author: %{name: "Agent"}
    }
  end
end
