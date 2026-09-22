defmodule ReyCode.Orchestration.ProviderRoundRecovery do
  @moduledoc "Pure replay-safety policy for one failed ProviderRound attempt."

  alias ReyCode.Failure
  alias ReyCode.Orchestration.{Invocation, ProviderRoundAttempt, ToolRuns}

  @maximum_attempt_count 3
  @retry_delays_ms %{1 => 1_000, 2 => 3_000}
  @maximum_failure_message_bytes 4_096

  @type decision ::
          {:schedule_retry, ProviderRoundAttempt.t(), pos_integer()}
          | {:fail, Failure.t()}

  @doc "Chooses a bounded retry only when Projection proves replay is safe."
  @spec decide(Invocation.t(), Failure.t(), DateTime.t()) :: decision()
  def decide(%Invocation{} = invocation, %Failure{} = failure, %DateTime{} = now) do
    case invocation.provider_round_attempt do
      %ProviderRoundAttempt{state: :started} = attempt ->
        decide_started(invocation, attempt, failure, now)

      _other ->
        {:fail, terminal_failure(failure, "provider attempt state is unavailable")}
    end
  end

  @doc "Maximum number of external attempts allowed for one ProviderRound."
  @spec maximum_attempt_count() :: pos_integer()
  def maximum_attempt_count, do: @maximum_attempt_count

  @doc "Returns the maximum wait scheduled after one failed attempt."
  @spec retry_delay_ms(pos_integer()) :: pos_integer()
  def retry_delay_ms(attempt), do: Map.fetch!(@retry_delays_ms, attempt)

  @doc "Returns the remaining retry wait, rejecting timestamps beyond the attempt policy."
  @spec retry_wait_ms(ProviderRoundAttempt.t(), DateTime.t()) ::
          non_neg_integer() | :invalid_retry_schedule
  def retry_wait_ms(
        %ProviderRoundAttempt{state: :retry_scheduled} = scheduled,
        %DateTime{} = now
      ) do
    {:ok, eligible_at, _offset} = DateTime.from_iso8601(scheduled.retry_eligible_at)
    maximum_wait_ms = retry_delay_ms(scheduled.attempt)

    remaining_ms = DateTime.diff(eligible_at, now, :millisecond)

    cond do
      remaining_ms > maximum_wait_ms -> :invalid_retry_schedule
      remaining_ms > 0 -> remaining_ms
      true -> 0
    end
  end

  @doc "Whether durable round state proves work can resume without replaying a provider request."
  @spec durable_continuation?(Invocation.t()) :: boolean()
  def durable_continuation?(%Invocation{} = invocation) do
    invocation.provider_round_attempt == nil and invocation.rounds != [] and
      not ToolRuns.started?(invocation)
  end

  defp decide_started(invocation, attempt, failure, now) do
    cond do
      not Failure.retryable?(failure) ->
        {:fail, failure}

      invocation.last_frame_sequence != attempt.frame_sequence_at_start ->
        {:fail, terminal_failure(failure, "partial provider output was recorded")}

      ToolRuns.started?(invocation) ->
        {:fail, terminal_failure(failure, "a tool execution is indeterminate")}

      attempt.attempt >= @maximum_attempt_count ->
        {:fail,
         exhausted_failure(
           failure,
           "provider retry limit of #{@maximum_attempt_count} attempts was exhausted"
         )}

      true ->
        delay_ms = retry_delay_ms(attempt.attempt)
        eligible_at = DateTime.add(now, delay_ms, :millisecond) |> DateTime.to_iso8601()

        scheduled = %{
          attempt
          | state: :retry_scheduled,
            retry_eligible_at: eligible_at,
            last_failure: bounded_failure(failure)
        }

        {:schedule_retry, scheduled, delay_ms}
    end
  end

  defp terminal_failure(%Failure{retryable?: false} = failure, _reason), do: failure

  defp terminal_failure(failure, reason) do
    Failure.new(
      failure.category,
      bounded_message(failure.message <> "; automatic retry stopped because " <> reason),
      false,
      failure.cause
    )
  end

  defp exhausted_failure(failure, reason) do
    %{failure | message: bounded_message(failure.message <> "; " <> reason), cause: nil}
  end

  defp bounded_failure(failure) do
    %{failure | message: bounded_message(failure.message), cause: nil}
  end

  defp bounded_message(message) when byte_size(message) <= @maximum_failure_message_bytes,
    do: message

  defp bounded_message(message) do
    marker = "..."
    available_bytes = @maximum_failure_message_bytes - byte_size(marker)

    clipped =
      message
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {kept, bytes} ->
        next_bytes = bytes + byte_size(grapheme)

        if next_bytes <= available_bytes,
          do: {:cont, {[grapheme | kept], next_bytes}},
          else: {:halt, {kept, bytes}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    clipped <> marker
  end
end
