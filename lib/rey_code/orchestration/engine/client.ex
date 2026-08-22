defmodule ReyCode.Orchestration.Engine.Client do
  @moduledoc "Internal process protocol used by supervised invocation workers."

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

  @doc """
  Claims the next actionable tool run of the latest round.

  Replies `{:ok, :none}` when every recorded call has a terminal run, or
  `{:ok, {:execute | :await | :denied | :busy, run}}` for the next call in
  order. The awaiting decision is persisted before replying, so a pause is
  durable even if the worker dies immediately afterwards.
  """
  @spec take_tool_run(GenServer.server(), String.t()) ::
          {:ok, :none} | {:ok, {atom(), map()}} | {:error, term()}
  def take_tool_run(server, invocation_id) do
    GenServer.call(server, {:take_tool_run, invocation_id}, :infinity)
  end

  @spec tool_run_started(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
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

  @spec fail_invocation(GenServer.server(), String.t(), map()) :: :ok
  def fail_invocation(server, invocation_id, error) do
    GenServer.call(server, {:fail_invocation, invocation_id, error}, :infinity)
  end
end
