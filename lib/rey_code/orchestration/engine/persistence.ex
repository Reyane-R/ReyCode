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

  # Attached terminals poll for the events since their last sequence instead
  # of copying the whole projection. The ring covers a few seconds of the
  # busiest streaming; a client further behind receives a full snapshot.
  @recent_events_count 512

  @doc "Appends entries and projects them without emitting runtime side effects."
  @spec append_and_project!(map(), [EventStore.entry()]) :: map()
  def append_and_project!(state, entries) do
    events = append!(entries, state.event_store, state.projection.sequence)

    events
    |> Enum.reduce(state, &project(&2, &1))
    |> remember_events(events)
  end

  @doc """
  Events appended after `sequence`, when the bounded ring still holds them.

  Returns `{:ok, []}` for a client that is current, `{:ok, events}` in append
  order, or `:stale` when the gap exceeds the ring and a snapshot is needed.
  """
  @spec events_since(map(), integer()) :: {:ok, [ReyCode.Event.t()]} | :stale
  def events_since(state, sequence) do
    recent = Map.get(state, :recent_events, [])

    cond do
      sequence >= state.projection.sequence ->
        {:ok, []}

      recent != [] and hd(recent).sequence <= sequence + 1 ->
        {:ok, Enum.filter(recent, &(&1.sequence > sequence))}

      true ->
        :stale
    end
  end

  defp remember_events(state, events) do
    recent = Map.get(state, :recent_events, []) ++ events
    Map.put(state, :recent_events, Enum.take(recent, -@recent_events_count))
  end

  # Every append pins the projection's own sequence as the store's expected
  # sequence, so a second writer inserting events this projection never
  # applied fails the transaction instead of being silently checkpointed over.
  #
  # The committed batch is projected event-by-event internally, but published
  # once at the transaction boundary: subscribers observe command-transaction
  # snapshots only, never intermediate state from a partially applied batch.
  @doc "Atomically appends entries, then projects, checkpoints, and broadcasts the batch."
  @spec append_and_apply!(map(), [EventStore.entry()]) :: map()
  def append_and_apply!(state, entries) do
    events = append!(entries, state.event_store, state.projection.sequence)
    projection = Enum.reduce(events, state.projection, &Projector.apply/2)

    maybe_checkpoint(projection, state)
    broadcast_snapshot(projection, state.event_registry)

    remember_events(%{state | projection: projection}, events)
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

  # A batch that crosses one or more checkpoint intervals checkpoints once,
  # at the final batch sequence, so the durable snapshot is always a valid
  # projection and no intermediate snapshot reaches subscribers.
  defp maybe_checkpoint(projection, state) do
    interval = state.config.persistence.checkpoint_interval

    crossed_interval? =
      div(projection.sequence, interval) > div(state.projection.sequence, interval)

    if crossed_interval? do
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
