defmodule ReyCode.Orchestration.ToolApprovalTest do
  use ExUnit.Case, async: true

  alias ReyCode.Event
  alias ReyCode.Orchestration.{Projector, Validation}

  defp invocation do
    %{
      id: "invocation-1",
      message_id: "message-1",
      turn_id: "turn-1",
      room_id: "room-1",
      status: :running,
      error: nil,
      pending_tool_review: nil
    }
  end

  defp event(type, data, sequence) do
    Event.new(sequence, type, data,
      aggregate_type: :invocation,
      aggregate_id: "invocation-1",
      room_id: "room-1",
      correlation_id: "turn-1"
    )
  end

  test "tool approval events are known and validate their required data" do
    assert :tool_ask_requested in Event.types()
    assert :tool_ask_resolved in Event.types()

    requested = %{
      "invocation_id" => "invocation-1",
      "message_id" => "message-1",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "request_id" => "request-1",
      "tool" => "write",
      "arguments" => %{"path" => "file.txt"},
      "workspace" => "/tmp/workspace"
    }

    assert event(:tool_ask_requested, requested, 1).type == :tool_ask_requested
  end

  test "requested tool approval is projected durably and approve clears it" do
    requested =
      event(
        :tool_ask_requested,
        %{
          "invocation_id" => "invocation-1",
          "message_id" => "message-1",
          "turn_id" => "turn-1",
          "room_id" => "room-1",
          "request_id" => "request-1",
          "tool" => "write",
          "arguments" => %{"path" => "file.txt"},
          "workspace" => "/tmp/workspace"
        },
        1
      )

    state =
      Projector.apply(requested, %{
        Projector.initial()
        | invocations: %{"invocation-1" => invocation()}
      })

    projected = state.invocations["invocation-1"]

    assert projected.status == :waiting_tool_approval
    assert projected.pending_tool_review.tool == "write"

    assert {:ok, _review, :approve} =
             Validation.tool_run_resolution(projected, "request-1", "approve")

    assert {:error, :tool_run_not_found} =
             Validation.tool_run_resolution(projected, "other-run", "approve")

    resolved =
      event(
        :tool_ask_resolved,
        %{
          "invocation_id" => "invocation-1",
          "message_id" => "message-1",
          "turn_id" => "turn-1",
          "room_id" => "room-1",
          "request_id" => "request-1",
          "tool" => "write",
          "decision" => "approve"
        },
        2
      )

    final = Projector.apply(resolved, state).invocations["invocation-1"]
    assert final.status == :running
    assert final.pending_tool_review == nil
  end
end
