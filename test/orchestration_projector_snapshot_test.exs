defmodule ReyCode.Orchestration.ProjectorSnapshotTest do
  @moduledoc """
  Legacy checkpoint compatibility.

  Projection snapshots written before durable tool runs exist lack the
  `rounds`, `tool_runs`, and `tool_run_order` invocation fields. Replaying
  them must normalize the invocation shape instead of crashing recovery.
  """

  use ExUnit.Case, async: true

  alias ReyCode.Event
  alias ReyCode.Orchestration.{Invocation, Participant, Projector}

  test "snapshots without tool-run fields replay into normalized invocations" do
    legacy_invocation = %{
      id: "inv-legacy",
      session_id: "room-1",
      turn_id: "turn-1",
      message_id: "msg-1",
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "build",
        provider: :simulator,
        model: nil
      },
      stage: 0,
      phase: "independent response",
      cycle: 0,
      logical_work_id: "inv-legacy",
      dependencies: [],
      label: "independent response",
      system_prompt: "Respond",
      status: :running,
      attempt: 1,
      usage: nil,
      provider_activity_events: [],
      pending_tool_review: nil,
      last_frame_sequence: 4,
      error: nil
    }

    legacy_state =
      Projector.initial()
      |> Map.put(:invocations, %{"inv-legacy" => legacy_invocation})
      |> Map.put(:sequence, 12)
      |> Map.drop([:last_snapshot_sequence])

    binary = legacy_state |> :erlang.term_to_binary() |> Base.encode64()

    snapshot_event =
      Event.new(13, :snapshot_recorded, %{"binary" => binary},
        aggregate_type: :system,
        aggregate_id: "projection"
      )

    restored = Projector.apply(snapshot_event, Projector.initial())

    invocation = restored.invocations["inv-legacy"]
    assert %Invocation{} = invocation
    assert %Participant{} = invocation.participant

    assert invocation.rounds == []
    assert invocation.phase_index == 0
    assert invocation.tool_runs == %{}
    assert invocation.tool_run_order == []
    assert invocation.pending_tool_review == nil
    assert invocation.status == :running
  end
end
