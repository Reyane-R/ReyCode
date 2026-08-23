defmodule ReyCode.EventStoreTest do
  use ExUnit.Case, async: true

  alias ReyCode.EventStore

  test "versioned room events survive a store restart in sequence order" do
    path = tmp_path("events-v2.sqlite3")
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

  test "writes and reloads a multi-event append as one transaction" do
    path = tmp_path("transaction.sqlite3")
    {store, id} = start_store(path)
    metadata = metadata()

    assert {:ok, events} =
             EventStore.append_many(
               [
                 {:room_created, event_data(:room_created), metadata},
                 {:message_posted, event_data(:message_posted), metadata}
               ],
               store
             )

    assert Enum.map(events, & &1.sequence) == [1, 2]

    stop_supervised!(id)
    {restarted_store, _id} = start_store(path)
    assert Enum.map(EventStore.load(restarted_store), & &1.sequence) == [1, 2]
  end

  test "rejects retired NDJSON store paths with migration guidance" do
    path = tmp_path("legacy.ndjson")

    assert {:error, {:ndjson_no_longer_supported, message}} = isolated_start(path)
    assert message =~ "legacy_path"
  end

  test "rejects an explicit retired backend option" do
    path = tmp_path("retired-backend.sqlite3")

    assert {:error, {:ndjson_no_longer_supported, message}} =
             isolated_start(path, backend: :ndjson)

    assert message =~ "SQLite-only"
  end

  test "rejects a second owner for the same expanded path and allows restart" do
    path = tmp_path("exclusive.sqlite3")
    {store, id} = start_store(path)
    equivalent_path = Path.join([Path.dirname(path), ".", Path.basename(path)])

    assert {:error, {:already_started, ^store}} =
             isolated_start(equivalent_path)

    stop_supervised!(id)
    {_restarted_store, _id} = start_store(equivalent_path)
  end

  test "rejects a second owner for the same file through a symlink" do
    path = tmp_path("canonical/real.sqlite3")
    alias_path = tmp_path("canonical/alias.sqlite3")
    File.mkdir_p!(Path.dirname(alias_path))
    File.ln_s!(path, alias_path)
    {store, _id} = start_store(path)

    assert {:error, {:already_started, ^store}} = isolated_start(alias_path)
  end

  test "fails explicitly when the ownership path parent is missing" do
    path = tmp_path("missing-parent/events.sqlite3")

    assert {:error, {:ownership_path_unavailable, :enoent}} = isolated_start(path)
  end

  defp tmp_path(filename) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "rey_code_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, filename)
  end

  defp event_data(:room_created) do
    %{
      "room_id" => "room-1",
      "slug" => "alpha",
      "title" => "Alpha",
      "workspace" => "/tmp/alpha",
      "participants" => []
    }
  end

  defp event_data(:message_posted) do
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

  defp start_store(path, extra \\ []) do
    File.mkdir_p!(Path.dirname(path))
    id = {EventStore, System.unique_integer([:positive])}
    spec = Supervisor.child_spec({EventStore, [name: nil, path: path] ++ extra}, id: id)
    {start_supervised!(spec), id}
  end

  defp isolated_start(path, extra \\ []) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(caller, {ref, EventStore.start_link([name: nil, path: path] ++ extra)})
    end)

    assert_receive {^ref, result}, 1_000
    result
  end
end
