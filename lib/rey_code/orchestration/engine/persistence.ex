defmodule ReyCode.Orchestration.Engine.Persistence do
  @moduledoc "Durable append, projection, checkpoint, and projection broadcast mechanics."

  alias ReyCode.EventStore
  alias ReyCode.Orchestration.Projector

  require Logger

  defmodule DurableAppendError do
    @moduledoc "Raised to fail-stop the engine when an event transaction is not durable."

    defexception [:reason, :entry_count]

    @impl true
    def message(error) do
      "durable orchestration append failed for #{error.entry_count} entries: #{inspect(error.reason)}"
    end
  end

  defmodule DurableLoadError do
    @moduledoc "Raised when the engine cannot restore its durable projection."

    defexception [:reason]

    @impl true
    def message(error), do: "durable orchestration restore failed: #{inspect(error.reason)}"
  end

  @doc "Restores the latest durable orchestration projection."
  @spec restore!(GenServer.server()) :: Projector.state()
  def restore!(event_store) do
    case EventStore.load_projection(event_store) do
      {:ok, checkpoint, events} ->
        Projector.replay(events, checkpoint || Projector.initial())

      {:error, reason} ->
        raise DurableLoadError, reason: reason
    end
  end

  @doc "Appends entries and projects them without emitting runtime side effects."
  @spec append_and_project!(map(), [EventStore.entry()]) :: map()
  def append_and_project!(state, entries) do
    entries
    |> append!(state.event_store)
    |> Enum.reduce(state, &project(&2, &1))
  end

  @doc "Atomically appends entries, then projects, checkpoints, and broadcasts each event."
  @spec append_and_apply!(map(), [EventStore.entry()]) :: map()
  def append_and_apply!(state, entries) do
    entries
    |> append!(state.event_store)
    |> Enum.reduce(state, &apply_and_broadcast(&2, &1))
  end

  defp append!(entries, event_store) do
    case EventStore.append_many(entries, event_store) do
      {:ok, events} ->
        events

      {:error, reason} ->
        raise DurableAppendError, reason: reason, entry_count: length(entries)
    end
  end

  defp project(state, event) do
    %{state | projection: Projector.apply(event, state.projection)}
  end

  defp apply_and_broadcast(state, event) do
    projection = Projector.apply(event, state.projection)
    maybe_checkpoint(projection, state)
    broadcast_snapshot(projection, state.event_registry)
    %{state | projection: projection}
  end

  defp maybe_checkpoint(projection, state) do
    event_store = state.event_store

    interval = ReyCode.RuntimeConfig.policy(state.config, :projection_checkpoint_interval, 500)

    if projection.sequence > 0 and rem(projection.sequence, interval) == 0 do
      case EventStore.checkpoint(projection, event_store) do
        :ok -> :ok
        {:error, reason} -> Logger.error("projection checkpoint failed: #{inspect(reason)}")
      end
    end
  end

  defp broadcast_snapshot(projection, registry) do
    Registry.dispatch(registry, :orchestration, fn entries ->
      Enum.each(entries, fn {pid, _value} ->
        send(pid, {:projection_snapshot, projection})
      end)
    end)
  end
end
