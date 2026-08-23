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

  defmodule DurableCheckpointError do
    @moduledoc """
    Raised when a projection checkpoint cannot be persisted.

    Checkpointing is a recoverability requirement, not an optimization: an
    engine that keeps appending while checkpoints fail drifts toward the
    replay limit and an unrecoverable startup. Permanent checkpoint failures
    fail-stop instead.
    """

    defexception [:reason]

    @impl true
    def message(error), do: "projection checkpoint failed: #{inspect(error.reason)}"
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
    |> append!(state.event_store, state.projection.sequence)
    |> Enum.reduce(state, &project(&2, &1))
  end

  # Every append pins the projection's own sequence as the store's expected
  # sequence, so a second writer inserting events this projection never
  # applied fails the transaction instead of being silently checkpointed over.
  @doc "Atomically appends entries, then projects, checkpoints, and broadcasts each event."
  @spec append_and_apply!(map(), [EventStore.entry()]) :: map()
  def append_and_apply!(state, entries) do
    entries
    |> append!(state.event_store, state.projection.sequence)
    |> Enum.reduce(state, &apply_and_broadcast(&2, &1))
  end

  defp append!(entries, event_store, expected_sequence) do
    case EventStore.append_many(entries, event_store, expected_sequence: expected_sequence) do
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
    interval = ReyCode.RuntimeConfig.policy(state.config, :projection_checkpoint_interval, 500)

    if projection.sequence > 0 and rem(projection.sequence, interval) == 0 do
      projection
      |> EventStore.checkpoint(state.event_store)
      |> handle_checkpoint_result()
    end
  end

  defp handle_checkpoint_result(:ok), do: :ok

  # A too-large projection never shrinks on its own; continuing would let the
  # replay tail grow past max_replay_events and make an intact event log
  # unrecoverable. Fail-stop so the operator raises :max_checkpoint_bytes
  # deliberately.
  defp handle_checkpoint_result({:error, {:checkpoint_too_large, _, _} = reason}) do
    raise DurableCheckpointError, reason: reason
  end

  # Transient storage errors are retried at the next interval while startup
  # remains recoverable through the full-replay fallback.
  defp handle_checkpoint_result({:error, reason}) do
    Logger.error("projection checkpoint failed: #{inspect(reason)}")
  end

  defp broadcast_snapshot(projection, registry) do
    Registry.dispatch(registry, :orchestration, fn entries ->
      Enum.each(entries, fn {pid, _value} ->
        send(pid, {:projection_snapshot, projection})
      end)
    end)
  end
end
