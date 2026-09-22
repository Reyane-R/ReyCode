defmodule ReyCode.Orchestration.ProviderRoundRecoveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.Failure

  alias ReyCode.Orchestration.{
    Invocation,
    Projection,
    ProviderRound,
    ProviderRoundAttempt,
    ProviderRoundRecovery
  }

  alias ReyCode.Orchestration.Engine.Loop

  @now ~U[2026-09-22 10:00:00.000Z]

  test "schedules a bounded retry when no frame was recorded" do
    invocation = invocation(attempt: 1)
    failure = Failure.new(:rate_limited, "try later", true)

    assert {:schedule_retry, scheduled, 1_000} =
             ProviderRoundRecovery.decide(invocation, failure, @now)

    assert scheduled.state == :retry_scheduled
    assert scheduled.attempt == 1
    assert scheduled.retry_eligible_at == "2026-09-22T10:00:01.000Z"
    assert scheduled.last_failure == failure
  end

  test "fails closed after partial provider output" do
    invocation = %{invocation(attempt: 1) | last_frame_sequence: 8}
    failure = Failure.new(:timeout, "timed out", true)

    assert {:fail, terminal} = ProviderRoundRecovery.decide(invocation, failure, @now)
    refute terminal.retryable?
    assert terminal.message =~ "partial provider output"
  end

  test "fails closed when the per-round attempt bound is exhausted" do
    invocation = invocation(attempt: ProviderRoundRecovery.maximum_attempt_count())
    failure = Failure.new(:server_error, "unavailable", true)

    assert {:fail, terminal} = ProviderRoundRecovery.decide(invocation, failure, @now)
    assert terminal.retryable?
    assert terminal.message =~ "retry limit"
  end

  test "uses the second bounded retry delay" do
    invocation = invocation(attempt: 2)
    failure = Failure.new(:server_error, "unavailable", true)

    assert {:schedule_retry, scheduled, 3_000} =
             ProviderRoundRecovery.decide(invocation, failure, @now)

    assert scheduled.retry_eligible_at == "2026-09-22T10:00:03.000Z"
  end

  test "publishes only the bounded retry delays" do
    assert ProviderRoundRecovery.retry_delay_ms(1) == 1_000
    assert ProviderRoundRecovery.retry_delay_ms(2) == 3_000
    assert_raise KeyError, fn -> ProviderRoundRecovery.retry_delay_ms(3) end
  end

  test "clock skew beyond the policy delay rejects the schedule" do
    scheduled = %ProviderRoundAttempt{
      round_index: 0,
      attempt: 1,
      frame_sequence_at_start: 0,
      provider_id: "zai",
      state: :retry_scheduled,
      retry_eligible_at: "2030-01-01T00:00:00.000Z",
      last_failure: Failure.new(:rate_limited, "try later", true)
    }

    assert ProviderRoundRecovery.retry_wait_ms(scheduled, @now) == :invalid_retry_schedule
    assert ProviderRoundRecovery.retry_wait_ms(scheduled, ~U[2030-01-01 00:00:00.000Z]) == 0
  end

  test "does not transform a non-retryable provider failure" do
    invocation = invocation(attempt: 1)
    failure = Failure.new(:authentication_failed, "bad key")

    assert {:fail, ^failure} = ProviderRoundRecovery.decide(invocation, failure, @now)
  end

  test "Engine rejects retry identity drift before appending an attempt" do
    started = invocation(attempt: 1)

    scheduled = %{
      started.provider_round_attempt
      | state: :retry_scheduled,
        retry_eligible_at: "2026-09-22T10:00:01.000Z",
        last_failure: Failure.new(:rate_limited, "try later", true)
    }

    invocation = %{started | id: "inv-1", provider_round_attempt: scheduled}
    state = %{projection: %Projection{invocations: %{invocation.id => invocation}}}

    assert {:reply, {:error, :provider_retry_identity_changed}, ^state} =
             Loop.start_provider_round_attempt(state, invocation.id, "openai", "glm-4.7", nil)
  end

  test "recognizes a recorded final round as replay-safe durable continuation" do
    invocation = %Invocation{
      rounds: [%ProviderRound{index: 0, text: "complete", tool_calls: []}],
      pending_steering: []
    }

    assert ProviderRoundRecovery.durable_continuation?(invocation)
  end

  defp invocation(options) do
    attempt = Keyword.fetch!(options, :attempt)

    %Invocation{
      status: :running,
      last_frame_sequence: 7,
      provider_round_attempt: %ProviderRoundAttempt{
        round_index: 0,
        attempt: attempt,
        frame_sequence_at_start: 7,
        provider_id: "zai",
        model_id: "glm-4.7",
        state: :started
      }
    }
  end
end
