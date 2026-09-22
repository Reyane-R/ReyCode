defmodule ReyCode.Orchestration.ProjectorSnapshotTest do
  @moduledoc """
  Legacy checkpoint compatibility.

  Projection snapshots written before durable tool runs exist lack the
  `rounds`, `tool_runs`, and `tool_run_order` invocation fields. Replaying
  them must normalize the invocation shape instead of crashing recovery.
  """

  use ExUnit.Case, async: true

  alias ReyCode.{Event, Failure}
  alias ReyCode.Orchestration.{Invocation, Participant, Projector, ProviderRoundAttempt}

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
    assert invocation.execution_context.context_boundary == nil
    assert invocation.provider_round_attempt == nil
    assert invocation.status == :running
  end

  test "checkpoint maps restore the typed provider round attempt" do
    invocation = %{
      id: "inv-attempt",
      session_id: "room-1",
      turn_id: "turn-1",
      message_id: "msg-1",
      status: :running,
      last_frame_sequence: 7,
      provider_round_attempt: %{
        "round_index" => 1,
        "attempt" => 2,
        "frame_sequence_at_start" => 7,
        "provider_id" => "openai",
        "model_id" => "gpt-5",
        "request_metrics" => %{
          "prompt_bytes" => 12_000,
          "estimated_prompt_tokens" => 3_000
        },
        "state" => "retry_scheduled",
        "retry_eligible_at" => "2026-09-22T12:00:01.000Z",
        "last_failure" => %{
          "category" => "rate_limited",
          "message" => "Try later",
          "retryable" => true
        }
      }
    }

    legacy_state =
      Projector.initial()
      |> Map.put(:invocations, %{"inv-attempt" => invocation})
      |> Map.put(:sequence, 20)

    snapshot_event =
      Event.new(
        21,
        :snapshot_recorded,
        %{"binary" => legacy_state |> :erlang.term_to_binary() |> Base.encode64()},
        aggregate_type: :system,
        aggregate_id: "projection"
      )

    restored = Projector.apply(snapshot_event, Projector.initial())
    attempt = restored.invocations["inv-attempt"].provider_round_attempt

    assert %ProviderRoundAttempt{state: :retry_scheduled, attempt: 2} = attempt
    assert %ProviderRoundAttempt.RequestMetrics{prompt_bytes: 12_000} = attempt.request_metrics
    assert %Failure{category: :rate_limited, retryable?: true} = attempt.last_failure
  end

  test "partial provider attempt checkpoint state fails closed" do
    assert_raise ArgumentError, ~r/invalid provider round attempt/, fn ->
      ProviderRoundAttempt.from_map(%{
        "round_index" => 0,
        "attempt" => 1,
        "state" => "started"
      })
    end
  end
end
