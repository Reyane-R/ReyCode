defmodule ReyCode.Orchestration.Engine.Client do
  @moduledoc """
  Internal process protocol used by supervised InvocationWorkers.

  Requests and start notifications use the default bounded GenServer timeout.
  Frame, ProviderRound, ToolRun, and terminal transitions wait indefinitely
  because each call crosses the EventStore durability point; timing out after
  an unknown commit would make retry safety unknowable. The InvocationWorker
  owns cancellation and is supervised. Duplicate frames are idempotent;
  state transitions reject stale or invalid source states with tagged errors.
  """

  alias ReyCode.Failure
  alias ReyCode.Orchestration.{InvocationContextBoundary, ProviderRoundAttempt}

  alias ReyCode.Provider.Frame

  @spec invocation_request(GenServer.server(), String.t()) :: term()
  def invocation_request(server, invocation_id) do
    GenServer.call(server, {:invocation_request, invocation_id})
  end

  @spec invocation_started(GenServer.server(), String.t()) :: :ok
  def invocation_started(server, invocation_id) do
    GenServer.call(server, {:invocation_started, invocation_id})
  end

  @spec record_frames(GenServer.server(), String.t(), [Frame.t()]) :: :ok | {:error, term()}
  def record_frames(server, invocation_id, frames) when is_list(frames) do
    GenServer.call(server, {:record_frames, invocation_id, frames}, :infinity)
  end

  @spec record_frame(GenServer.server(), String.t(), Frame.t()) :: :ok | {:error, term()}
  def record_frame(server, invocation_id, %Frame{} = frame) do
    record_frames(server, invocation_id, [frame])
  end

  @doc "Durably records the attempt before one external provider request begins."
  @spec start_provider_round_attempt(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t() | nil,
          ProviderRoundAttempt.RequestMetrics.t() | nil
        ) :: {:ok, pos_integer()} | {:wait, pos_integer()} | {:error, term()}
  def start_provider_round_attempt(server, invocation_id, provider_id, model_id, request_metrics) do
    GenServer.call(
      server,
      {:start_provider_round_attempt, invocation_id, provider_id, model_id, request_metrics},
      :infinity
    )
  end

  @doc "Durably schedules a replay-safe retry or terminalizes the Invocation."
  @spec provider_round_failed(GenServer.server(), String.t(), Failure.t()) ::
          {:retry_scheduled, pos_integer()} | :failed
  def provider_round_failed(server, invocation_id, %Failure{} = failure) do
    GenServer.call(server, {:provider_round_failed, invocation_id, failure}, :infinity)
  end

  @doc """
  Records one normalized provider round.

  Replies `{:ok, :final}` when the round carried no tool calls (the loop is
  done), or `{:ok, :continue}` when its calls must be drained before the next
  round.
  """
  @spec record_round(GenServer.server(), String.t(), non_neg_integer(), map()) ::
          {:ok, :final | :continue} | {:error, term()}
  def record_round(server, invocation_id, round_index, response_wire) do
    GenServer.call(server, {:record_round, invocation_id, round_index, response_wire}, :infinity)
  end

  @doc "Builds the next Invocation context boundary from authoritative projected state."
  @spec prepare_context_boundary(GenServer.server(), String.t(), pos_integer()) ::
          :unchanged | {:ok, InvocationContextBoundary.t()} | {:error, term()}
  def prepare_context_boundary(server, invocation_id, max_summary_bytes) do
    GenServer.call(server, {:prepare_context_boundary, invocation_id, max_summary_bytes})
  end

  @doc "Records one validated Invocation context boundary durably and idempotently."
  @spec record_context_boundary(GenServer.server(), String.t(), InvocationContextBoundary.t()) ::
          :ok | {:error, term()}
  def record_context_boundary(server, invocation_id, %InvocationContextBoundary{} = boundary) do
    GenServer.call(server, {:record_context_boundary, invocation_id, boundary}, :infinity)
  end

  @doc "Compacts an eligible Session prefix under an exact preflight allowance."
  @spec compact_session_context(GenServer.server(), String.t(), pos_integer()) ::
          :ok | :unchanged | {:error, term()}
  def compact_session_context(server, invocation_id, max_summary_bytes) do
    GenServer.call(
      server,
      {:compact_session_context, invocation_id, max_summary_bytes},
      :infinity
    )
  end

  @doc """
  Claims the next actionable tool run of the latest round.

  Replies `{:ok, :complete}` when a final ProviderRound only needs its durable
  Invocation completion, `{:ok, :none}` when the next ProviderRound is due, or
  `{:ok, {:execute | :await | :denied | :busy, run}}` for the next call in
  order. The awaiting decision is persisted before replying, so a pause is
  durable even if the worker dies immediately afterwards.
  """
  @spec take_tool_run(GenServer.server(), String.t()) ::
          {:ok, :none | :complete}
          | {:ok, {atom(), map()}}
          | {:waiting, atom()}
          | {:error, term()}
  def take_tool_run(server, invocation_id) do
    GenServer.call(server, {:take_tool_run, invocation_id}, :infinity)
  end

  @spec tool_run_started(GenServer.server(), String.t(), String.t()) ::
          :ok | {:ok, ReyCode.Tool.Request.t()} | {:error, term()}
  def tool_run_started(server, invocation_id, run_id) do
    GenServer.call(server, {:tool_run_started, invocation_id, run_id}, :infinity)
  end

  @spec tool_run_completed(GenServer.server(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def tool_run_completed(server, invocation_id, run_id, result) do
    GenServer.call(server, {:tool_run_completed, invocation_id, run_id, result}, :infinity)
  end

  @spec tool_run_failed(GenServer.server(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def tool_run_failed(server, invocation_id, run_id, error) do
    GenServer.call(server, {:tool_run_failed, invocation_id, run_id, error}, :infinity)
  end

  @spec complete_invocation(GenServer.server(), String.t(), map()) :: :ok
  def complete_invocation(server, invocation_id, metadata) do
    GenServer.call(server, {:complete_invocation, invocation_id, metadata}, :infinity)
  end

  @spec fail_invocation(GenServer.server(), String.t(), Failure.t()) :: :ok
  def fail_invocation(server, invocation_id, error) do
    GenServer.call(server, {:fail_invocation, invocation_id, error}, :infinity)
  end
end
