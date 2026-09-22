defmodule ReyCode.Orchestration.ProviderRoundAttempt.RequestMetrics do
  @moduledoc "Fixed, bounded request measurements captured before one provider attempt."

  @max_metric_value 9_223_372_036_854_775_807
  @enforce_keys [:prompt_bytes, :estimated_prompt_tokens]
  defstruct prompt_bytes: 0,
            estimated_prompt_tokens: 0,
            max_prompt_bytes: nil,
            input_budget_tokens: nil

  @type t :: %__MODULE__{
          prompt_bytes: non_neg_integer(),
          estimated_prompt_tokens: non_neg_integer(),
          max_prompt_bytes: pos_integer() | nil,
          input_budget_tokens: pos_integer() | nil
        }

  @doc "Builds request metrics from the exact prompt bytes and estimated prompt tokens."
  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(prompt_bytes, estimated_prompt_tokens)
      when is_integer(prompt_bytes) and prompt_bytes >= 0 and
             prompt_bytes <= @max_metric_value and is_integer(estimated_prompt_tokens) and
             estimated_prompt_tokens >= 0 and estimated_prompt_tokens <= @max_metric_value do
    %__MODULE__{
      prompt_bytes: prompt_bytes,
      estimated_prompt_tokens: estimated_prompt_tokens
    }
  end

  @doc "Builds complete request occupancy metrics from model-aware preflight."
  @spec new(non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()) :: t()
  def new(prompt_bytes, estimated_prompt_tokens, max_prompt_bytes, input_budget_tokens)
      when is_integer(max_prompt_bytes) and max_prompt_bytes > 0 and
             max_prompt_bytes <= @max_metric_value and is_integer(input_budget_tokens) and
             input_budget_tokens > 0 and input_budget_tokens <= @max_metric_value do
    %{
      new(prompt_bytes, estimated_prompt_tokens)
      | max_prompt_bytes: max_prompt_bytes,
        input_budget_tokens: input_budget_tokens
    }
  end

  @doc "Converts checkpoint or event metrics into the typed record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = metrics), do: metrics

  def from_map(metrics) when is_map(metrics) do
    prompt_bytes = fetch!(metrics, :prompt_bytes)
    estimated_prompt_tokens = fetch!(metrics, :estimated_prompt_tokens)
    max_prompt_bytes = fetch(metrics, :max_prompt_bytes)
    input_budget_tokens = fetch(metrics, :input_budget_tokens)

    if is_nil(max_prompt_bytes) and is_nil(input_budget_tokens) do
      new(prompt_bytes, estimated_prompt_tokens)
    else
      new(prompt_bytes, estimated_prompt_tokens, max_prompt_bytes, input_budget_tokens)
    end
  end

  @doc "Converts typed request metrics to their fixed event representation."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = metrics) do
    %{
      "prompt_bytes" => metrics.prompt_bytes,
      "estimated_prompt_tokens" => metrics.estimated_prompt_tokens
    }
    |> optional_metric("max_prompt_bytes", metrics.max_prompt_bytes)
    |> optional_metric("input_budget_tokens", metrics.input_budget_tokens)
  end

  @doc "Validates and restores the exact request-metrics event shape."
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_request_metrics}
  def from_wire(
        %{
          "prompt_bytes" => _prompt_bytes,
          "estimated_prompt_tokens" => _estimated_prompt_tokens
        } = metrics
      ) do
    allowed = ~w(prompt_bytes estimated_prompt_tokens max_prompt_bytes input_budget_tokens)

    if Enum.all?(Map.keys(metrics), &(&1 in allowed)) do
      {:ok, from_map(metrics)}
    else
      {:error, :invalid_request_metrics}
    end
  rescue
    FunctionClauseError -> {:error, :invalid_request_metrics}
    KeyError -> {:error, :invalid_request_metrics}
  end

  def from_wire(_metrics), do: {:error, :invalid_request_metrics}

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp optional_metric(metrics, _key, nil), do: metrics
  defp optional_metric(metrics, key, value), do: Map.put(metrics, key, value)
end

defmodule ReyCode.Orchestration.ProviderRoundAttempt do
  @moduledoc "The current durable attempt to obtain one ProviderRound."

  alias __MODULE__.RequestMetrics
  alias ReyCode.Failure

  @fields [
    :round_index,
    :attempt,
    :frame_sequence_at_start,
    :provider_id,
    :model_id,
    :request_metrics,
    :state,
    :retry_eligible_at,
    :last_failure
  ]

  @enforce_keys [:round_index, :attempt, :frame_sequence_at_start, :provider_id, :state]
  defstruct round_index: 0,
            attempt: 1,
            frame_sequence_at_start: 0,
            provider_id: nil,
            model_id: nil,
            request_metrics: nil,
            state: :started,
            retry_eligible_at: nil,
            last_failure: nil

  @type state :: :started | :retry_scheduled

  @type t :: %__MODULE__{
          round_index: non_neg_integer(),
          attempt: pos_integer(),
          frame_sequence_at_start: non_neg_integer(),
          provider_id: String.t(),
          model_id: String.t() | nil,
          request_metrics: RequestMetrics.t() | nil,
          state: state(),
          retry_eligible_at: String.t() | nil,
          last_failure: Failure.t() | nil
        }

  @doc "Converts a decoded checkpoint map into the typed attempt record."
  @spec from_map(t() | map()) :: t()
  def from_map(attempt) when is_map(attempt) do
    values =
      Map.new(@fields, fn field ->
        {field, fetch(attempt, field, field_default(field))}
      end)

    attempt = struct!(__MODULE__, values)

    %{
      attempt
      | request_metrics: optional_metrics(attempt.request_metrics),
        state: state(attempt.state),
        last_failure: optional_failure(attempt.last_failure)
    }
    |> validate!()
  end

  defp optional_metrics(nil), do: nil
  defp optional_metrics(metrics), do: RequestMetrics.from_map(metrics)

  defp optional_failure(nil), do: nil
  defp optional_failure(failure), do: Failure.from_map(failure)

  defp state(:started), do: :started
  defp state(:retry_scheduled), do: :retry_scheduled
  defp state("started"), do: :started
  defp state("retry_scheduled"), do: :retry_scheduled

  defp state(_invalid), do: raise(ArgumentError, "invalid provider round attempt state")

  defp validate!(%__MODULE__{} = attempt) do
    with :ok <- non_negative_integer(attempt.round_index),
         :ok <- bounded_attempt(attempt.attempt),
         :ok <- non_negative_integer(attempt.frame_sequence_at_start),
         :ok <- non_empty_string(attempt.provider_id),
         :ok <- optional_string(attempt.model_id),
         true <- valid_state_fields?(attempt) do
      attempt
    else
      _invalid -> raise ArgumentError, "invalid provider round attempt"
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp non_negative_integer(_value), do: :error

  defp bounded_attempt(value) when is_integer(value) and value in 1..3, do: :ok
  defp bounded_attempt(_value), do: :error

  defp non_empty_string(value) when is_binary(value) and value != "", do: :ok
  defp non_empty_string(_value), do: :error

  defp optional_string(nil), do: :ok
  defp optional_string(value) when is_binary(value), do: :ok
  defp optional_string(_value), do: :error

  defp valid_state_fields?(%__MODULE__{
         state: :started,
         retry_eligible_at: nil,
         last_failure: nil
       }),
       do: true

  defp valid_state_fields?(%__MODULE__{
         state: :retry_scheduled,
         attempt: attempt,
         retry_eligible_at: retry_eligible_at,
         last_failure: %Failure{retryable?: true}
       })
       when attempt < 3 and is_binary(retry_eligible_at) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(retry_eligible_at))
  end

  defp valid_state_fields?(_attempt), do: false

  defp field_default(field)
       when field in [:model_id, :request_metrics, :retry_eligible_at, :last_failure],
       do: nil

  defp field_default(_required), do: :missing

  defp fetch(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
