defmodule ReyCode.Agent do
  @moduledoc """
  A supervised execution bridge for one provider invocation.

  The process owns buffering, lifecycle, and error containment around
  `ReyCode.AgentLoop`, which performs the durable round/tool-run steps.
  """

  use GenServer, restart: :temporary

  alias ReyCode.AgentLoop
  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Provider.{Response, Runtime}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry = Keyword.fetch!(opts, :registry)
    invocation_id = Keyword.fetch!(opts, :invocation_id)
    name = {:via, Registry, {registry, invocation_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @frame_batch_size 16
  @buffer_key :frames

  @type state :: %{
          required(:engine) => term(),
          required(:invocation_id) => String.t(),
          required(:provider) => atom() | String.t(),
          required(:provider_catalog) => term(),
          optional(atom()) => term()
        }

  @type step :: {:stop, state()}

  @impl true
  def init(opts) do
    {:ok, Map.new(opts), {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    case AgentLoop.run(state) do
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  @doc "Streams one provider round with frame buffering and error containment."
  @spec stream(state(), map(), Runtime.t()) :: {:ok, Response.t()} | {:error, map()}
  def stream(state, request, runtime) do
    buffer = :ets.new(__MODULE__, [:set, :public])

    emit = fn frame -> enqueue_frame(state.engine, buffer, state.invocation_id, frame) end

    result =
      try do
        runtime.module.stream(runtime, request, emit)
      rescue
        error ->
          {:error, internal_error(Exception.message(error))}
      catch
        kind, reason ->
          {:error, internal_error(Exception.format_banner(kind, reason))}
      end

    flush = flush_frame_buffer(state.engine, buffer, state.invocation_id)
    :ets.delete(buffer)

    case {result, flush} do
      {{:error, _error} = result, _flush} ->
        result

      {_result, {:error, reason}} ->
        {:error, internal_error("frame flush rejected: " <> inspect(reason))}

      {result, :ok} ->
        result
    end
  end

  @doc "Executes one ready tool run through the registry and records its outcome."
  @spec execute_tool_run(state(), map()) :: :ok
  def execute_tool_run(state, run), do: AgentLoop.execute_tool_run(state, run)

  @doc "Fails the invocation with a provider-shaped error."
  @spec fail(state(), map()) :: :ok
  def fail(state, error) do
    :ok = Client.fail_invocation(state.engine, state.invocation_id, error)
  end

  @spec provider_error(atom()) :: String.t()
  def provider_error(:missing), do: "Provider executable is not installed"
  def provider_error(:available), do: "Provider needs credentials or an available model"
  def provider_error(:unchecked), do: "Provider discovery is disabled"
  def provider_error(:model_required), do: "Select a model before running this agent"
  def provider_error(:model_unavailable), do: "The selected model is no longer available"
  def provider_error(:unknown_provider), do: "Unknown provider runtime"
  def provider_error(:provider_check_timeout), do: "Provider discovery timed out"
  def provider_error(reason), do: "Provider is unavailable: #{inspect(reason)}"

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue_frame(engine, buffer, invocation_id, frame) do
    frames = [frame | buffered_frames(buffer)]

    if length(frames) >= @frame_batch_size do
      true = :ets.delete(buffer, @buffer_key)
      record_batch!(engine, invocation_id, frames)
    else
      true = :ets.insert(buffer, {@buffer_key, frames})
      :ok
    end
  end

  defp buffered_frames(buffer) do
    case :ets.lookup(buffer, @buffer_key) do
      [{@buffer_key, frames}] -> frames
      [] -> []
    end
  end

  defp flush_frame_buffer(engine, buffer, invocation_id) do
    case :ets.take(buffer, @buffer_key) do
      [{@buffer_key, frames}] -> Client.record_frames(engine, invocation_id, Enum.reverse(frames))
      [] -> :ok
    end
  end

  defp record_batch!(engine, invocation_id, frames) do
    case Client.record_frames(engine, invocation_id, Enum.reverse(frames)) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "frame batch rejected: " <> inspect(reason)
    end
  end

  defp internal_error(message) do
    %{"category" => "internal", "message" => message, "retryable" => false}
  end
end
