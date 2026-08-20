defmodule ReyCode.Agent do
  @moduledoc "A supervised execution bridge for one provider invocation."

  use GenServer, restart: :temporary

  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Provider.Catalog

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry = Keyword.fetch!(opts, :registry)
    invocation_id = Keyword.fetch!(opts, :invocation_id)
    name = {:via, Registry, {registry, invocation_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @frame_batch_size 16
  @buffer_key :frames

  @impl true
  def init(opts) do
    {:ok, Map.new(opts), {:continue, :stream}}
  end

  @impl true
  def handle_continue(:stream, state) do
    case Client.invocation_request(state.engine, state.invocation_id) do
      {:terminal, _status} ->
        {:stop, :normal, state}

      {:ok, request} ->
        start_request(state, request)
    end
  end

  defp start_request(state, request) do
    case Catalog.resolve_when_ready(
           state.provider,
           request.participant.model,
           state.provider_catalog
         ) do
      {:ok, runtime} ->
        :ok = Client.invocation_started(state.engine, state.invocation_id)

        execute(state, request, runtime)

      {:error, reason} ->
        fail_unavailable_provider(state, reason)
    end
  end

  defp fail_unavailable_provider(state, reason) do
    error = %{
      "category" => "provider_unavailable",
      "message" => provider_error(reason),
      "retryable" => reason in [:provider_checking, :provider_check_timeout, :error]
    }

    :ok = Client.fail_invocation(state.engine, state.invocation_id, error)

    {:stop, :normal, state}
  end

  defp execute(state, request, runtime) do
    buffer = :ets.new(__MODULE__, [:set, :public])
    emit = fn frame -> enqueue_frame(state.engine, buffer, state.invocation_id, frame) end

    result =
      try do
        stream(runtime, request, emit)
      rescue
        error ->
          {:error, internal_error(Exception.message(error))}
      catch
        kind, reason ->
          {:error, internal_error(Exception.format_banner(kind, reason))}
      end

    flush = flush_frame_buffer(state.engine, buffer, state.invocation_id)
    :ets.delete(buffer)

    cond do
      match?({:error, _}, result) ->
        {:error, error} = result
        Client.fail_invocation(state.engine, state.invocation_id, error)

      flush != :ok ->
        {:error, reason} = flush
        error = internal_error("frame flush rejected: " <> inspect(reason))
        Client.fail_invocation(state.engine, state.invocation_id, error)

      true ->
        {:ok, metadata} = result
        Client.complete_invocation(state.engine, state.invocation_id, metadata)
    end

    {:stop, :normal, state}
  end

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

  defp stream(runtime, request, emit) do
    runtime.module.stream(runtime, request, emit)
  end

  @spec provider_error(atom()) :: String.t()
  defp provider_error(:missing), do: "Provider executable is not installed"
  defp provider_error(:available), do: "Provider needs credentials or an available model"
  defp provider_error(:unchecked), do: "Provider discovery is disabled"
  defp provider_error(:model_required), do: "Select a model before running this agent"
  defp provider_error(:model_unavailable), do: "The selected model is no longer available"
  defp provider_error(:unknown_provider), do: "Unknown provider runtime"
  defp provider_error(:provider_check_timeout), do: "Provider discovery timed out"
  defp provider_error(reason), do: "Provider is unavailable: #{reason}"
end
