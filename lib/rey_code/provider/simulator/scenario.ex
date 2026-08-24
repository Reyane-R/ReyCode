defmodule ReyCode.Provider.Simulator.Scenario do
  @moduledoc "Deterministic delay, failure, and leader-rework scenario."

  alias ReyCode.Failure
  alias ReyCode.Hashing

  defstruct seed: 0,
            delay_ms: 0,
            jitter_ms: 0,
            failure_rate: 0.0,
            failure_plan: %{},
            leader_rework_rounds: 0,
            rework_phase: "release_gate",
            emit_process: :caller,
            tool_requests: []

  @type failure_kind ::
          :retryable | :permanent | :crash | :timeout | :invalid_output | :after_frame

  @type t :: %__MODULE__{
          seed: integer(),
          delay_ms: non_neg_integer(),
          jitter_ms: non_neg_integer(),
          failure_rate: float(),
          failure_plan: map(),
          leader_rework_rounds: non_neg_integer(),
          rework_phase: String.t(),
          emit_process: :caller | :task,
          tool_requests: [map()]
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      seed: Map.get(opts, :seed, 0),
      delay_ms: max(Map.get(opts, :delay_ms, 0), 0),
      jitter_ms: max(Map.get(opts, :jitter_ms, 0), 0),
      failure_rate: opts |> Map.get(:failure_rate, 0.0) |> min(1.0) |> max(0.0),
      failure_plan: Map.get(opts, :failure_plan, %{}),
      leader_rework_rounds: max(Map.get(opts, :leader_rework_rounds, 0), 0),
      rework_phase: Map.get(opts, :rework_phase, "release_gate"),
      emit_process: Map.get(opts, :emit_process, :caller),
      tool_requests: Map.get(opts, :tool_requests, [])
    }
  end

  @spec sample(t(), map()) :: %{delay_ms: non_neg_integer(), failure: failure_kind() | nil}
  def sample(scenario, request) do
    key = {scenario.seed, request.turn_id, request.logical_work_id, request.attempt}
    value = deterministic_integer(key)
    spread = scenario.jitter_ms * 2 + 1
    jitter = if spread == 1, do: 0, else: rem(value, spread) - scenario.jitter_ms
    delay = max(scenario.delay_ms + jitter, 0)

    failure =
      Map.get(scenario.failure_plan, request.logical_work_id) ||
        Map.get(scenario.failure_plan, {request.phase, request.participant.id, request.attempt}) ||
        random_failure(scenario.failure_rate, value)

    %{delay_ms: delay, failure: normalize_failure(failure)}
  end

  @doc false
  @spec failure_error(failure_kind()) :: Failure.t()
  def failure_error(:retryable), do: failure(:simulated_retryable, true)
  def failure_error(:permanent), do: failure(:simulated_permanent, false)
  def failure_error(:timeout), do: failure(:simulated_timeout, true)
  def failure_error(:invalid_output), do: failure(:invalid_squad_output, true)
  def failure_error(:after_frame), do: failure(:simulated_after_frame, true)
  def failure_error(:crash), do: failure(:worker_exit, true)

  defp random_failure(rate, _value) when rate <= 0.0, do: nil

  defp random_failure(rate, value) do
    if rem(value, 1_000_000) < trunc(rate * 1_000_000), do: :retryable
  end

  defp deterministic_integer(term) do
    <<value::unsigned-integer-size(64), _rest::binary>> =
      term |> :erlang.term_to_binary() |> Hashing.sha256()

    value
  end

  defp normalize_failure(value)
       when value in [:retryable, :permanent, :crash, :timeout, :invalid_output, :after_frame],
       do: value

  defp normalize_failure(_value), do: nil

  defp failure(category, retryable) do
    Failure.new(category, "Injected simulator failure", retryable)
  end
end
