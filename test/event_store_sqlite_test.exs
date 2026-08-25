defmodule ReyCode.EventStoreSQLiteTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Event, EventStore, Hashing}
  alias ReyCode.EventStore.Record
  alias ReyCode.EventStore.SQLite
  alias ReyCode.Orchestration.Projector

  test "creates the current schema and records its migration on a fresh database" do
    path = tmp_path("fresh-schema.sqlite3")

    assert {:ok, state} = SQLite.open(path)

    assert [[1]] = sqlite_rows(state.connection, "SELECT version FROM schema_migrations")

    assert Enum.sort(sqlite_table_names(state.connection)) ==
             ~w(checkpoints events schema_migrations store_metadata transactions)

    assert :ok = SQLite.close(state)

    assert {:ok, reopened} = SQLite.open(path)
    assert [[1]] = sqlite_rows(reopened.connection, "SELECT version FROM schema_migrations")
    assert :ok = SQLite.close(reopened)
  end

  test "preserves the mode of an existing database parent directory" do
    path = tmp_path("shared/fresh.sqlite3")
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o755)

    assert {:ok, state} = SQLite.open(path)
    assert :ok = SQLite.close(state)
    assert File.stat!(directory).mode |> Bitwise.band(0o777) == 0o755
  end

  test "hardens a newly created parent and database" do
    path = tmp_path("private/fresh.sqlite3")
    directory = Path.dirname(path)

    assert {:ok, state} = SQLite.open(path)
    assert :ok = SQLite.close(state)
    assert File.stat!(directory).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "applies a missing migration to an existing version table" do
    path = tmp_path("missing-migration.sqlite3")
    connection = open_sqlite(path)
    create_schema_migrations(connection)
    assert :ok = Exqlite.Sqlite3.close(connection)

    assert {:ok, state} = SQLite.open(path)
    assert [[1]] = sqlite_rows(state.connection, "SELECT version FROM schema_migrations")
    assert "events" in sqlite_table_names(state.connection)
    assert :ok = SQLite.close(state)
  end

  test "rejects a database migrated beyond the supported schema version" do
    path = tmp_path("future-schema.sqlite3")
    connection = open_sqlite(path)
    create_schema_migrations(connection)

    assert :done =
             sqlite_run(
               connection,
               "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
               [2, "2026-01-01T00:00:00Z"]
             )

    assert :ok = Exqlite.Sqlite3.close(connection)

    assert {:error, {:unsupported_schema_version, 2, 1}} = SQLite.open(path)
  end

  test "rolls back all changes when a migration step raises" do
    path = tmp_path("failed-migration.sqlite3")
    connection = open_sqlite(path)
    create_schema_migrations(connection)
    assert :ok = Exqlite.Sqlite3.execute(connection, "CREATE TABLE events (sequence INTEGER)")
    assert :ok = Exqlite.Sqlite3.close(connection)

    task =
      Task.async(fn ->
        try do
          SQLite.open(path)
        rescue
          error -> {error, __STACKTRACE__}
        end
      end)

    assert {%MatchError{}, stacktrace} = Task.await(task)
    assert Exception.format_stacktrace(stacktrace) =~ "apply_migration"

    connection = open_sqlite(path)
    refute "transactions" in sqlite_table_names(connection)
    assert [] = sqlite_rows(connection, "SELECT version FROM schema_migrations")
    assert :ok = Exqlite.Sqlite3.close(connection)
  end

  test "commits idempotent transactions with optimistic sequence checks" do
    path = tmp_path("events.sqlite3")
    {store, id} = start_store(path)
    entries = [{:room_created, room_data(), metadata()}]

    assert {:ok, [event]} =
             EventStore.append_many(entries, store,
               transaction_id: "create-room-1",
               expected_sequence: 0
             )

    assert event.sequence == 1

    assert {:ok, [same_event]} =
             EventStore.append_many(entries, store,
               transaction_id: "create-room-1",
               expected_sequence: 0
             )

    assert same_event == event

    assert {:error, {:conflict, 1}} =
             EventStore.append_many(entries, store,
               transaction_id: "create-room-2",
               expected_sequence: 0
             )

    assert {:ok, %{backend: :sqlite, sequence: 1}} = EventStore.verify(store)

    stop_supervised!(id)
    {restarted, _id} = start_store(path)
    assert EventStore.load(restarted) == [event]
  end

  test "creates and verifies a consistent owner-only backup" do
    path = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    {store, _id} = start_store(path)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())

    assert {:ok, manifest} = EventStore.backup(backup, store)
    assert manifest.sequence == 1
    assert {:ok, digest} = Hashing.file_sha256_hex(backup)
    assert manifest.sha256 == digest
    assert File.exists?(manifest.manifest)
    assert File.stat!(backup).mode |> Bitwise.band(0o777) == 0o600

    {backup_store, _id} = start_store(backup)
    assert Enum.map(EventStore.load(backup_store), & &1.sequence) == [1]
  end

  test "imports a legacy NDJSON log once and preserves a rollback copy" do
    directory = Path.dirname(tmp_path("placeholder"))
    legacy = Path.join(directory, "events-v2.ndjson")
    database = Path.join(directory, "rey_code.sqlite3")
    event = Event.new(1, :room_created, room_data(), metadata())
    contents = Record.encode!([event]) <> "\n"
    File.mkdir_p!(directory)
    File.write!(legacy, contents)

    {store, id} = start_store(database, legacy_path: legacy)
    assert EventStore.load(store) == [event]
    assert File.read!(legacy) == contents
    assert File.read!(legacy <> ".pre-sqlite-backup") == contents

    stop_supervised!(id)
    {restarted, _id} = start_store(database, legacy_path: legacy)
    assert EventStore.load(restarted) == [event]
  end

  test "loads a checksummed projection checkpoint plus its bounded event tail" do
    path = tmp_path("checkpoint.sqlite3")
    {store, _id} = start_store(path)

    assert {:ok, first} =
             EventStore.append(:room_created, room_data("room-1"), store, metadata("room-1"))

    checkpoint = Projector.replay([first])
    assert :ok = EventStore.checkpoint(checkpoint, store)

    assert {:ok, second} =
             EventStore.append(:room_created, room_data("room-2"), store, metadata("room-2"))

    assert {:ok, loaded_checkpoint, [tail]} = EventStore.load_projection(store)
    refute Map.has_key?(loaded_checkpoint.rooms["room-1"], :__struct__)
    assert Projector.replay([], loaded_checkpoint) == checkpoint
    assert tail == second

    assert Projector.replay([tail], loaded_checkpoint) ==
             store |> EventStore.load() |> Projector.replay()
  end

  test "normalizes retired schema-v2 events while restoring a checkpoint tail" do
    path = tmp_path("legacy-tail.sqlite3")
    {store, id} = start_store(path)

    assert {:ok, room} =
             EventStore.append(:room_created, room_data(), store, metadata())

    assert :ok = EventStore.checkpoint(Projector.replay([room]), store)

    invocation_metadata = [
      aggregate_type: :invocation,
      aggregate_id: "inv-1",
      room_id: "room-1"
    ]

    assert {:ok, delta} =
             EventStore.append(
               :provider_frame_recorded,
               %{
                 "invocation_id" => "inv-1",
                 "message_id" => "msg-1",
                 "frame_sequence" => 1,
                 "kind" => "text_delta",
                 "data" => %{"text" => "legacy text"}
               },
               store,
               invocation_metadata
             )

    assert {:ok, session} =
             EventStore.append(
               :provider_frame_recorded,
               %{
                 "invocation_id" => "inv-1",
                 "message_id" => "msg-1",
                 "frame_sequence" => 2,
                 "kind" => "session_started",
                 "data" => %{"session_id" => "session-1"}
               },
               store,
               invocation_metadata
             )

    stop_supervised!(id)
    connection = open_sqlite(path)

    replace_event_with_legacy_payload(
      connection,
      delta,
      "message_delta_appended",
      %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-1",
        "frame_sequence" => 1,
        "delta" => "legacy text"
      }
    )

    replace_event_with_legacy_payload(
      connection,
      session,
      "invocation_session_recorded",
      %{
        "invocation_id" => "inv-1",
        "frame_sequence" => 2,
        "session_id" => "session-1"
      }
    )

    assert :ok = Exqlite.Sqlite3.close(connection)
    {restarted, _id} = start_store(path)

    assert {:ok, _checkpoint, [replayed_delta, replayed_session]} =
             EventStore.load_projection(restarted)

    assert replayed_delta.type == :provider_frame_recorded

    assert replayed_delta.data == %{
             "invocation_id" => "inv-1",
             "message_id" => "msg-1",
             "frame_sequence" => 1,
             "kind" => "text_delta",
             "data" => %{"text" => "legacy text"}
           }

    assert replayed_session.type == :provider_frame_recorded

    assert replayed_session.data == %{
             "invocation_id" => "inv-1",
             "message_id" => nil,
             "frame_sequence" => 2,
             "kind" => "session_started",
             "data" => %{"session_id" => "session-1"}
           }
  end

  test "fails closed when the latest projection checkpoint is corrupted" do
    path = tmp_path("corrupt-checkpoint.sqlite3")
    {store, id} = start_store(path)

    assert {:ok, event} = EventStore.append(:room_created, room_data(), store, metadata())
    assert :ok = EventStore.checkpoint(Projector.replay([event]), store)
    stop_supervised!(id)

    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE checkpoints SET checksum = 'invalid'")
    :ok = Exqlite.Sqlite3.close(connection)

    {restarted, _id} = start_store(path)

    assert {:error, :checkpoint_checksum_mismatch} =
             EventStore.load_projection(restarted)
  end

  test "returns an invalid checkpoint error for malformed checkpoint terms" do
    path = tmp_path("malformed-checkpoint.sqlite3")
    {store, id} = start_store(path)

    assert {:ok, event} = EventStore.append(:room_created, room_data(), store, metadata())
    assert :ok = EventStore.checkpoint(Projector.replay([event]), store)
    stop_supervised!(id)

    payload = Jason.encode!(["map", [["not-a-key-value-pair"]]])
    connection = open_sqlite(path)

    assert :done =
             sqlite_run(connection, "UPDATE checkpoints SET payload = ?, checksum = ?", [
               payload,
               Hashing.sha256_hex(payload)
             ])

    assert :ok = Exqlite.Sqlite3.close(connection)

    {restarted, _id} = start_store(path)
    assert {:error, :invalid_checkpoint} = EventStore.load_projection(restarted)
  end

  test "reraises unexpected transaction exceptions with their stacktrace after rollback" do
    path = tmp_path("transaction-exception.sqlite3")
    assert {:ok, state} = SQLite.open(path)
    event = Event.new(1, :room_created, room_data(), metadata())
    malformed = %{event | type: "room_created"}

    result =
      try do
        SQLite.import_events(state, [malformed])
      rescue
        error -> {error, __STACKTRACE__}
      end

    assert {%ArgumentError{}, stacktrace} = result

    assert Exception.format_stacktrace(stacktrace) =~ "insert_event"
    assert [[0]] = sqlite_rows(state.connection, "SELECT COUNT(*) FROM transactions")

    assert {:ok, imported} = SQLite.import_events(state, [event])
    assert imported.sequence == 1
    assert [[1]] = sqlite_rows(state.connection, "SELECT COUNT(*) FROM transactions")
    assert :ok = SQLite.close(imported)
  end

  test "falls back to a full replay when the tail exceeds the replay policy" do
    path = tmp_path("replay-limit.sqlite3")
    {store, id} = start_store(path)

    assert {:ok, _first} =
             EventStore.append(:room_created, room_data("one"), store, metadata("one"))

    assert {:ok, _second} =
             EventStore.append(:room_created, room_data("two"), store, metadata("two"))

    stop_supervised!(id)

    {:ok, state} = SQLite.open(path)

    # A replay limit that the un-checkpointed tail exceeds must not make the
    # intact log unrecoverable: the store replays everything instead.
    assert {:ok, nil, events} = SQLite.load_projection(state, 1, 1_000_000)
    assert Enum.map(events, & &1.sequence) == [1, 2]
    assert :ok = SQLite.close(state)
  end

  test "the full-replay fallback starts at the legacy snapshot barrier" do
    path = tmp_path("replay-barrier.sqlite3")
    {store, id} = start_store(path)

    Enum.each(1..3, fn i ->
      assert {:ok, _event} =
               EventStore.append(
                 :room_created,
                 room_data("room-#{i}"),
                 store,
                 metadata("room-#{i}")
               )
    end)

    stop_supervised!(id)

    connection = open_sqlite(path)

    :done =
      sqlite_run(
        connection,
        "UPDATE events SET type = 'message_delta_appended' WHERE sequence = 1",
        []
      )

    :done =
      sqlite_run(
        connection,
        "UPDATE events SET type = 'snapshot_recorded' WHERE sequence = 2",
        []
      )

    :ok = Exqlite.Sqlite3.close(connection)

    {:ok, state} = SQLite.open(path)

    # Sequence 1 carries a retired type that can no longer decode; the
    # fallback must replay from the barrier at sequence 2, not from zero.
    assert {:ok, nil, events} = SQLite.load_projection(state, 1, 1_000_000)
    assert Enum.map(events, & &1.sequence) == [2, 3]
    assert :ok = SQLite.close(state)
  end

  defp start_store(path, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    id = {EventStore, System.unique_integer([:positive])}

    spec =
      Supervisor.child_spec(
        {EventStore, [name: nil, path: path, backend: :sqlite] ++ opts},
        id: id
      )

    {start_supervised!(spec), id}
  end

  defp open_sqlite(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    connection
  end

  defp create_schema_migrations(connection) do
    :ok =
      Exqlite.Sqlite3.execute(connection, """
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
      """)
  end

  defp sqlite_table_names(connection) do
    connection
    |> sqlite_rows("""
    SELECT name FROM sqlite_schema
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """)
    |> Enum.map(fn [name] -> name end)
  end

  defp sqlite_rows(connection, sql, params \\ []) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(connection, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(statement, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(connection, statement)
      rows
    after
      Exqlite.Sqlite3.release(connection, statement)
    end
  end

  defp sqlite_run(connection, sql, params) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(connection, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(statement, params)
      Exqlite.Sqlite3.step(connection, statement)
    after
      Exqlite.Sqlite3.release(connection, statement)
    end
  end

  defp replace_event_with_legacy_payload(connection, event, type, data) do
    payload =
      event
      |> Event.encode!()
      |> Jason.decode!()
      |> Map.merge(%{"type" => type, "data" => data})
      |> Jason.encode!()

    assert :done =
             sqlite_run(
               connection,
               "UPDATE events SET type = ?, payload = ? WHERE sequence = ?",
               [type, payload, event.sequence]
             )
  end

  defp room_data(room_id \\ "room-1") do
    %{
      "room_id" => room_id,
      "slug" => room_id,
      "title" => room_id,
      "workspace" => System.tmp_dir!(),
      "participants" => []
    }
  end

  defp metadata(room_id \\ "room-1") do
    [aggregate_type: :room, aggregate_id: room_id, room_id: room_id]
  end

  defp tmp_path(filename) do
    Path.join(
      System.tmp_dir!(),
      "rey_code_sqlite_#{System.pid()}_#{System.unique_integer([:positive])}/#{filename}"
    )
  end
end
