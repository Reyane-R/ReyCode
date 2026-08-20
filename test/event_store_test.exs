defmodule ReyCode.EventStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReyCode.{Event, EventStore}

  test "versioned room events survive a store restart in sequence order" do
    path = tmp_path("events-v2.ndjson")
    {store, id} = start_store(path)

    metadata = [aggregate_type: :room, aggregate_id: "room-1", room_id: "room-1"]

    assert {:ok, first} =
             EventStore.append(
               :room_created,
               %{
                 "room_id" => "room-1",
                 "slug" => "alpha",
                 "title" => "Alpha",
                 "workspace" => "/tmp/alpha",
                 "participants" => []
               },
               store,
               metadata
             )

    assert first.sequence == 1
    assert first.schema_version == 2

    stop_supervised!(id)
    {restarted_store, _id} = start_store(path)

    assert [replayed] = EventStore.load(restarted_store)
    assert replayed.type == :room_created
    assert replayed.aggregate_id == "room-1"
    assert replayed.data["title"] == "Alpha"
  end

  test "loads legacy schema-v2 one-event-per-line records" do
    path = tmp_path("legacy.ndjson")
    first = event(1, :room_created)
    second = event(2, :message_posted)
    write!(path, Event.encode!(first) <> "\n" <> Event.encode!(second))

    {store, id} = start_store(path)

    assert Enum.map(EventStore.load(store), & &1.sequence) == [1, 2]

    assert {:ok, appended} =
             EventStore.append(
               :turn_completed,
               %{"turn_id" => "turn-1", "room_id" => "room-1", "outcome" => "completed"},
               store,
               metadata()
             )

    assert appended.sequence == 3

    stop_supervised!(id)
    {restarted_store, _id} = start_store(path)
    assert Enum.map(EventStore.load(restarted_store), & &1.sequence) == [1, 2, 3]
  end

  test "writes and reloads a multi-event append as one transaction record" do
    path = tmp_path("transaction.ndjson")
    {store, id} = start_store(path)
    metadata = metadata()

    assert {:ok, events} =
             EventStore.append_many(
               [
                 {:room_created, event_data(:room_created, 1), metadata},
                 {:message_posted, event_data(:message_posted, 2), metadata}
               ],
               store
             )

    assert Enum.map(events, & &1.sequence) == [1, 2]
    assert [line, ""] = path |> File.read!() |> String.split("\n")
    envelope = Jason.decode!(line)
    assert envelope["first_sequence"] == 1
    assert envelope["event_count"] == 2
    assert length(envelope["events"]) == 2

    stop_supervised!(id)
    {restarted_store, _id} = start_store(path)
    assert Enum.map(EventStore.load(restarted_store), & &1.sequence) == [1, 2]
  end

  test "truncates and warns about an incomplete unterminated final tail" do
    path = tmp_path("torn-tail.ndjson")
    complete = Event.encode!(event(1, :room_created)) <> "\n"
    write!(path, complete <> ~s({"record_type":"transaction","first_sequence":2))

    log =
      capture_log(fn ->
        {store, _id} = start_store(path)
        assert Enum.map(EventStore.load(store), & &1.sequence) == [1]
      end)

    assert log =~ "truncated incomplete event log tail"
    assert File.read!(path) == complete
  end

  test "fails to load a malformed complete record" do
    path = tmp_path("malformed.ndjson")
    write!(path, Event.encode!(event(1, :room_created)) <> "\nnot-json\n")

    assert {:error, {%Jason.DecodeError{}, _stacktrace}} =
             isolated_start(path)
  end

  test "validates transaction metadata and the global event sequence" do
    invalid_count_path = tmp_path("invalid-count.ndjson")

    write!(
      invalid_count_path,
      Jason.encode!(%{
        "record_type" => "transaction",
        "first_sequence" => 1,
        "event_count" => 2,
        "events" => [event_value(1)]
      }) <> "\n"
    )

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             isolated_start(invalid_count_path)

    assert message =~ "event_count"

    sequence_gap_path = tmp_path("sequence-gap.ndjson")
    write!(sequence_gap_path, Event.encode!(event(2, :room_created)) <> "\n")

    assert {:error, {%RuntimeError{message: "event log sequence is not contiguous"}, _stacktrace}} =
             isolated_start(sequence_gap_path)
  end

  test "rejects a second owner for the same expanded path and allows restart" do
    path = tmp_path("exclusive.ndjson")
    {store, id} = start_store(path)
    equivalent_path = Path.join([Path.dirname(path), ".", Path.basename(path)])

    assert {:error, {:already_started, ^store}} =
             isolated_start(equivalent_path)

    stop_supervised!(id)
    {_restarted_store, _id} = start_store(equivalent_path)
  end

  test "rejects a second owner for the same file through a symlink" do
    path = tmp_path("canonical/real.ndjson")
    alias_path = tmp_path("canonical/alias.ndjson")
    write!(path, "")
    File.mkdir_p!(Path.dirname(alias_path))
    File.ln_s!(path, alias_path)
    {store, _id} = start_store(path)

    assert {:error, {:already_started, ^store}} = isolated_start(alias_path)
  end

  test "fails explicitly when the ownership path parent is missing" do
    path = tmp_path("missing-parent/events.ndjson")

    assert {:error, {:ownership_path_unavailable, :enoent}} = isolated_start(path)
  end

  test "loads only events from the last snapshot onward" do
    path = tmp_path("snapshot-trim.ndjson")

    write!(
      path,
      Event.encode!(event(1, :room_created)) <>
        "\n" <>
        Event.encode!(event(2, :message_posted)) <>
        "\n" <>
        Event.encode!(snapshot_event(3)) <>
        "\n" <>
        Event.encode!(event(4, :message_posted)) <> "\n"
    )

    {store, _id} = start_store(path)
    assert Enum.map(EventStore.load(store), & &1.sequence) == [3, 4]

    assert {:ok, appended} =
             EventStore.append(
               :turn_completed,
               %{"turn_id" => "turn-1", "room_id" => "room-1", "outcome" => "completed"},
               store,
               metadata()
             )

    assert appended.sequence == 5
  end

  test "normalizes a complete unterminated tail before the next append" do
    path = tmp_path("unterminated-tail.ndjson")

    write!(
      path,
      Event.encode!(event(1, :room_created)) <> "\n" <> Event.encode!(event(2, :message_posted))
    )

    {store, id} = start_store(path)

    assert {:ok, appended} =
             EventStore.append(
               :turn_completed,
               %{"turn_id" => "turn-1", "room_id" => "room-1", "outcome" => "completed"},
               store,
               metadata()
             )

    assert appended.sequence == 3

    stop_supervised!(id)
    {restarted_store, _id} = start_store(path)
    assert Enum.map(EventStore.load(restarted_store), & &1.sequence) == [1, 2, 3]
  end

  defp tmp_path(filename) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "rey_code_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, filename)
  end

  defp event(sequence, type) do
    Event.new(sequence, type, event_data(type, sequence), metadata())
  end

  defp snapshot_event(sequence) do
    Event.new(
      sequence,
      :snapshot_recorded,
      %{"binary" => "snap"},
      aggregate_type: :system,
      aggregate_id: "snapshot",
      room_id: nil
    )
  end

  defp event_data(:room_created, _sequence) do
    %{
      "room_id" => "room-1",
      "slug" => "alpha",
      "title" => "Alpha",
      "workspace" => "/tmp/alpha",
      "participants" => []
    }
  end

  defp event_data(:message_posted, _sequence) do
    %{
      "message_id" => "msg-1",
      "room_id" => "room-1",
      "turn_id" => "turn-1",
      "body" => "Hello"
    }
  end

  defp metadata do
    [aggregate_type: :room, aggregate_id: "room-1", room_id: "room-1"]
  end

  defp event_value(sequence) do
    sequence
    |> event(:room_created)
    |> Event.encode!()
    |> Jason.decode!()
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp start_store(path) do
    File.mkdir_p!(Path.dirname(path))
    id = {EventStore, System.unique_integer([:positive])}
    spec = Supervisor.child_spec({EventStore, name: nil, path: path}, id: id)
    {start_supervised!(spec), id}
  end

  defp isolated_start(path) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(caller, {ref, EventStore.start_link(name: nil, path: path)})
    end)

    assert_receive {^ref, result}, 1_000
    result
  end
end
