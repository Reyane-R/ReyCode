defmodule ReyCode.Orchestration.Engine.PersistenceTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine.Persistence
  alias ReyCode.Orchestration.Engine.Persistence.{DurableAppendError, DurableLoadError}
  alias ReyCode.Orchestration.Projector

  defmodule FailingStore do
    use GenServer

    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)
    def init(reason), do: {:ok, reason}

    def handle_call({:append_many, _entries, _opts}, _from, reason) do
      {:reply, {:error, reason}, reason}
    end

    def handle_call(:load_projection, _from, reason), do: {:reply, {:error, reason}, reason}
  end

  test "raises an explicit fail-stop error when a durable append fails" do
    store = start_supervised!({FailingStore, :disk_full})

    state = %{
      projection: Projector.initial(),
      event_store: store,
      event_registry: __MODULE__.UnusedRegistry
    }

    error =
      assert_raise DurableAppendError, fn ->
        Persistence.append_and_apply!(state, [
          {:event_that_will_not_persist, %{}, aggregate_type: :system}
        ])
      end

    assert error.reason == :disk_full
    assert error.entry_count == 1
    assert Exception.message(error) =~ "durable orchestration append failed"
  end

  test "raises an explicit fail-stop error when durable restore fails" do
    store = start_supervised!({FailingStore, :corrupt_store})

    error = assert_raise DurableLoadError, fn -> Persistence.restore!(store) end

    assert error.reason == :corrupt_store
    assert Exception.message(error) =~ "durable orchestration restore failed"
  end

  defmodule SequencedStore do
    @moduledoc false

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(initial_sequence: sequence),
      do: {:ok, %{sequence: sequence, checkpoint_sequences: []}}

    def handle_call({:append_many, entries, opts}, _from, state) do
      expected = Keyword.get(opts, :expected_sequence, state.sequence)

      if expected == state.sequence do
        {events, sequence} =
          Enum.map_reduce(entries, state.sequence, fn {type, data, metadata}, seq ->
            {ReyCode.Event.new(seq + 1, type, data, metadata), seq + 1}
          end)

        {:reply, {:ok, events}, %{state | sequence: sequence}}
      else
        {:reply, {:error, {:conflict, state.sequence}}, state}
      end
    end

    def handle_call({:checkpoint, projection}, _from, state) do
      {:reply, :ok,
       %{state | checkpoint_sequences: [projection.sequence | state.checkpoint_sequences]}}
    end
  end

  describe "transaction-boundary broadcasts" do
    test "projects the whole committed batch and publishes exactly one snapshot" do
      registry = :"persistence_events_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      store = start_supervised!({SequencedStore, initial_sequence: 1})
      state = room_state(store, registry)

      {:ok, _pid} = Registry.register(registry, :orchestration, nil)

      next = Persistence.append_and_apply!(state, turn_batch("room-1"))

      assert next.projection.sequence == 3

      assert_receive {:projection_snapshot, snapshot}, 500
      assert snapshot.sequence == 3
      assert Map.has_key?(snapshot.messages, "msg-1")
      assert Map.has_key?(snapshot.turns, "turn-1")
      assert snapshot.turns["turn-1"].user_message_id == "msg-1"

      refute_receive {:projection_snapshot, _}, 100
    end

    test "checkpoints once per interval-crossing batch at the final batch sequence" do
      registry = :"persistence_events_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      store = start_supervised!({SequencedStore, initial_sequence: 1})
      state = room_state(store, registry, 2)

      # Sequences 2..4 cross one multiple of the interval of 2.
      state = Persistence.append_and_apply!(state, message_entries("room-1", 3))
      assert checkpoints(store) == [4]

      # Sequence 5 stays inside the interval; sequence 6 crosses it.
      state = Persistence.append_and_apply!(state, message_entries("room-1", 1, offset: 4))
      assert checkpoints(store) == [4]

      _state = Persistence.append_and_apply!(state, message_entries("room-1", 1, offset: 5))
      assert checkpoints(store) == [4, 6]
    end
  end

  defp room_state(store, registry, interval \\ 5) do
    created =
      ReyCode.Event.new(
        1,
        :room_created,
        %{
          "room_id" => "room-1",
          "slug" => "alpha",
          "title" => "Alpha",
          "workspace" => "/tmp/alpha",
          "participants" => []
        },
        aggregate_type: :room,
        aggregate_id: "room-1",
        room_id: "room-1"
      )

    %{
      projection: Projector.replay([created]),
      event_store: store,
      event_registry: registry,
      config: %{persistence: %{checkpoint_interval: interval}}
    }
  end

  defp turn_batch(room_id) do
    [
      message_entry("msg-1", room_id, "turn-1", 0),
      {:turn_queued,
       %{
         "turn_id" => "turn-1",
         "room_id" => room_id,
         "user_message_id" => "msg-1",
         "mode" => "compare",
         "context_through_sequence" => 0,
         "participant_id" => nil
       }, aggregate_type: :turn, aggregate_id: "turn-1", room_id: room_id}
    ]
  end

  defp message_entries(room_id, count, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)

    Enum.map(1..count//1, fn index ->
      sequence = offset + index
      message_entry("msg-#{sequence}", room_id, nil, sequence - 1)
    end)
  end

  defp message_entry(message_id, room_id, turn_id, context_sequence) do
    {:message_posted,
     %{
       "message_id" => message_id,
       "room_id" => room_id,
       "turn_id" => turn_id,
       "body" => "hello",
       "author_name" => "You"
     },
     aggregate_type: :room,
     aggregate_id: room_id,
     room_id: room_id,
     correlation_id: "#{context_sequence}"}
  end

  defp checkpoints(store) do
    :sys.get_state(store).checkpoint_sequences
    |> Enum.reverse()
  end
end
