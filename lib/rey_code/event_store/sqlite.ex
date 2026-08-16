defmodule ReyCode.EventStore.SQLite do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias ReyCode.{Event, Hashing}

  @minimum_sqlite Version.parse!("3.51.3")
  @migrations [{1, :create_initial_schema}]
  @schema_version @migrations |> List.last() |> elem(0)
  @projection_version 2
  @checkpoint_retention 3

  @doc """
  Opens or creates a SQLite event store.

  The database parent is created with mode `0o700` only when it does not
  already exist. The database and SQLite sidecar files owned by ReyCode are
  hardened to mode `0o600` after initialization.
  """
  def open(path) do
    path = Path.expand(path)
    directory = Path.dirname(path)

    with :ok <- ensure_directory(directory),
         {:ok, connection} <- Sqlite3.open(path) do
      initialize(connection, path)
    end
  end

  defp ensure_directory(directory) do
    directory_exists = File.dir?(directory)

    with :ok <- File.mkdir_p(directory),
         :ok <- maybe_harden_new_directory(directory, directory_exists) do
      :ok
    end
  end

  defp maybe_harden_new_directory(_directory, true), do: :ok
  defp maybe_harden_new_directory(directory, false), do: File.chmod(directory, 0o700)

  def close(%{connection: connection}), do: Sqlite3.close(connection)

  defp initialize(connection, path) do
    result =
      with :ok <- configure(connection),
           :ok <- migrate(connection),
           {:ok, sequence} <-
             scalar(connection, "SELECT COALESCE(MAX(sequence), 0) FROM events") do
        secure_files(path)
        {:ok, %{backend: :sqlite, path: path, connection: connection, sequence: sequence}}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} = error ->
        _ = Sqlite3.close(connection)
        error
    end
  rescue
    error ->
      stacktrace = __STACKTRACE__
      _ = Sqlite3.close(connection)
      reraise error, stacktrace
  end

  def load(%{connection: connection}) do
    sql = """
    SELECT payload
    FROM events
    WHERE sequence >= COALESCE(
      (SELECT MAX(sequence) FROM events WHERE type = 'snapshot_recorded'),
      1
    )
    ORDER BY sequence
    """

    connection
    |> rows(sql)
    |> Enum.map(fn [payload] -> Event.decode!(payload) end)
  end

  def load_projection(%{connection: connection}, replay_limit, max_checkpoint_bytes) do
    case rows(connection, """
         SELECT sequence, projection_version, payload, checksum
         FROM checkpoints
         ORDER BY sequence DESC
         LIMIT 1
         """) do
      [] ->
        load_projection_tail(connection, nil, 0, replay_limit)

      [[sequence, version, payload, checksum]] ->
        with {:ok, projection} <-
               decode_checkpoint(sequence, version, payload, checksum, max_checkpoint_bytes) do
          load_projection_tail(connection, projection, sequence, replay_limit)
        end
    end
  end

  def checkpoint(%{connection: connection, sequence: store_sequence}, projection, max_bytes) do
    sequence = projection[:sequence]
    payload = projection |> encode_checkpoint_term() |> Jason.encode!()

    cond do
      not is_integer(sequence) or sequence <= 0 or sequence > store_sequence ->
        {:error, :invalid_checkpoint_sequence}

      byte_size(payload) > max_bytes ->
        {:error, {:checkpoint_too_large, byte_size(payload), max_bytes}}

      true ->
        checksum = Hashing.sha256_hex(payload)

        transaction(connection, fn ->
          run!(
            connection,
            """
            INSERT OR REPLACE INTO checkpoints(
              sequence, projection_version, payload, checksum, created_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            [sequence, @projection_version, payload, checksum, now()]
          )

          execute!(connection, """
          DELETE FROM checkpoints
          WHERE sequence NOT IN (
            SELECT sequence FROM checkpoints ORDER BY sequence DESC LIMIT #{@checkpoint_retention}
          )
          """)
        end)
    end
  end

  def append_many(state, entries, opts) do
    transaction_id = Keyword.get_lazy(opts, :transaction_id, &transaction_id/0)
    expected_sequence = Keyword.get(opts, :expected_sequence, state.sequence)

    case transaction_events(state.connection, transaction_id) do
      [] -> commit_entries(state, entries, transaction_id, expected_sequence)
      events -> {:ok, events, state}
    end
  end

  def import_events(state, []), do: {:ok, state}

  def import_events(%{sequence: 0} = state, events) do
    transaction_id = "legacy-ndjson-v2-import"
    connection = state.connection

    case transaction(connection, fn ->
           insert_transaction(connection, transaction_id, events)
           Enum.each(events, &insert_event(connection, transaction_id, &1))

           execute!(
             connection,
             "INSERT OR REPLACE INTO store_metadata(key, value) VALUES ('legacy_import', 'verified')"
           )
         end) do
      :ok -> {:ok, %{state | sequence: List.last(events).sequence}}
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  def import_events(state, _events), do: {:ok, state}

  def verify(%{connection: connection, path: path, sequence: sequence}) do
    with [["ok"]] <- rows(connection, "PRAGMA quick_check"),
         [] <- rows(connection, "PRAGMA foreign_key_check") do
      {:ok, %{backend: :sqlite, path: path, sequence: sequence}}
    else
      result -> {:error, {:integrity_check_failed, result}}
    end
  end

  def verify_path(path) do
    path = Path.expand(path)

    with {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
      try do
        with :ok <- verify_connection(connection),
             {:ok, sequence} <-
               scalar(connection, "SELECT COALESCE(MAX(sequence), 0) FROM events") do
          {:ok, %{backend: :sqlite, path: path, sequence: sequence}}
        end
      after
        Sqlite3.close(connection)
      end
    end
  end

  def backup(%{connection: connection, sequence: sequence}, destination) do
    destination = Path.expand(destination)

    if File.exists?(destination) do
      {:error, :destination_exists}
    else
      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- checkpoint(connection),
           :ok <- vacuum_into(connection, destination),
           :ok <- File.chmod(destination, 0o600),
           :ok <- verify_file(destination) do
        write_manifest(destination, sequence)
      end
    end
  end

  defp configure(connection) do
    with :ok <- Sqlite3.set_busy_timeout(connection, 5_000),
         :ok <- execute(connection, "PRAGMA locking_mode=EXCLUSIVE"),
         :ok <- execute(connection, "PRAGMA journal_mode=WAL"),
         :ok <- execute(connection, "PRAGMA synchronous=FULL"),
         :ok <- execute(connection, "PRAGMA fullfsync=ON"),
         :ok <- execute(connection, "PRAGMA checkpoint_fullfsync=ON"),
         :ok <- execute(connection, "PRAGMA foreign_keys=ON"),
         :ok <- execute(connection, "PRAGMA trusted_schema=OFF"),
         :ok <- execute(connection, "PRAGMA journal_size_limit=16777216"),
         {:ok, version} <- scalar(connection, "SELECT sqlite_version()"),
         :ok <- validate_sqlite_version(version),
         {:ok, "wal"} <- scalar(connection, "PRAGMA journal_mode") do
      :ok
    end
  end

  defp load_projection_tail(connection, projection, sequence, replay_limit) do
    event_rows =
      rows(
        connection,
        "SELECT payload FROM events WHERE sequence > ? ORDER BY sequence LIMIT ?",
        [sequence, replay_limit + 1]
      )

    if length(event_rows) > replay_limit do
      {:error, {:replay_limit_exceeded, sequence, replay_limit}}
    else
      events = Enum.map(event_rows, fn [payload] -> Event.decode!(payload) end)
      {:ok, projection, events}
    end
  end

  defp decode_checkpoint(sequence, version, encoded, checksum, max_bytes) do
    with true <- version == @projection_version || {:error, {:unsupported_projection, version}},
         true <- is_binary(encoded) || {:error, :invalid_checkpoint},
         true <- byte_size(encoded) <= max_bytes || {:error, :checkpoint_too_large},
         true <-
           Hashing.sha256_hex(encoded) == checksum || {:error, :checkpoint_checksum_mismatch},
         {:ok, wire} <- Jason.decode(encoded),
         {:ok, projection} <- decode_checkpoint_term(wire),
         true <- valid_projection?(projection, sequence) || {:error, :invalid_checkpoint} do
      {:ok, projection}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_checkpoint}
    end
  end

  defp valid_projection?(projection, sequence) do
    is_map(projection) and projection[:sequence] == sequence and
      Enum.all?(~w(rooms room_order messages turns invocations)a, &Map.has_key?(projection, &1))
  end

  defp encode_checkpoint_term(value) when is_atom(value), do: ["atom", Atom.to_string(value)]
  defp encode_checkpoint_term(value) when is_binary(value), do: ["binary", value]
  defp encode_checkpoint_term(value) when is_integer(value), do: ["integer", value]
  defp encode_checkpoint_term(value) when is_float(value), do: ["float", value]

  defp encode_checkpoint_term(value) when is_list(value) do
    ["list", Enum.map(value, &encode_checkpoint_term/1)]
  end

  defp encode_checkpoint_term(value) when is_tuple(value) do
    ["tuple", value |> Tuple.to_list() |> Enum.map(&encode_checkpoint_term/1)]
  end

  defp encode_checkpoint_term(value) when is_map(value) do
    pairs =
      Enum.map(value, fn {key, item} ->
        [encode_checkpoint_term(key), encode_checkpoint_term(item)]
      end)

    ["map", pairs]
  end

  defp decode_checkpoint_term(["atom", value]) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :invalid_checkpoint}
  end

  defp decode_checkpoint_term(["binary", value]) when is_binary(value), do: {:ok, value}
  defp decode_checkpoint_term(["integer", value]) when is_integer(value), do: {:ok, value}
  defp decode_checkpoint_term(["float", value]) when is_float(value), do: {:ok, value}

  defp decode_checkpoint_term(["list", values]) when is_list(values),
    do: decode_checkpoint_terms(values)

  defp decode_checkpoint_term(["tuple", values]) when is_list(values) do
    case decode_checkpoint_terms(values) do
      {:ok, decoded} -> {:ok, List.to_tuple(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_checkpoint_term(["map", pairs]) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      [encoded_key, encoded_value], {:ok, map} ->
        with {:ok, key} <- decode_checkpoint_term(encoded_key),
             {:ok, value} <- decode_checkpoint_term(encoded_value) do
          {:cont, {:ok, Map.put(map, key, value)}}
        else
          {:error, :invalid_checkpoint} = error -> {:halt, error}
        end

      _pair, _result ->
        {:halt, {:error, :invalid_checkpoint}}
    end)
  end

  defp decode_checkpoint_term(_value), do: {:error, :invalid_checkpoint}

  defp decode_checkpoint_terms(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decode_checkpoint_term(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, :invalid_checkpoint} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, :invalid_checkpoint} = error -> error
    end
  end

  defp validate_sqlite_version(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, @minimum_sqlite) == :lt,
          do: {:error, {:unsupported_sqlite, version}},
          else: :ok

      :error ->
        {:error, {:invalid_sqlite_version, version}}
    end
  end

  defp migrate(connection) do
    with :ok <- ensure_schema_migrations(connection),
         versions <- migration_versions(connection),
         :ok <- validate_schema_versions(versions) do
      apply_migrations(connection, versions)
    end
  end

  defp ensure_schema_migrations(connection) do
    transaction(connection, fn ->
      execute!(connection, """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
      """)
    end)
  end

  defp migration_versions(connection) do
    connection
    |> rows("SELECT version FROM schema_migrations ORDER BY version")
    |> Enum.map(fn [version] -> version end)
  end

  defp validate_schema_versions(versions) do
    case Enum.find(versions, &(&1 > @schema_version)) do
      nil -> :ok
      version -> {:error, {:unsupported_schema_version, version, @schema_version}}
    end
  end

  defp apply_migrations(connection, applied_versions) do
    pending = Enum.reject(@migrations, fn {version, _name} -> version in applied_versions end)

    transaction(connection, fn ->
      Enum.each(pending, fn {version, name} ->
        apply_migration(connection, name)

        run!(
          connection,
          "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
          [version, now()]
        )
      end)
    end)
  end

  defp apply_migration(connection, :create_initial_schema) do
    execute!(connection, """
    CREATE TABLE IF NOT EXISTS transactions (
      id TEXT PRIMARY KEY,
      first_sequence INTEGER NOT NULL,
      last_sequence INTEGER NOT NULL,
      event_count INTEGER NOT NULL CHECK (event_count > 0),
      committed_at TEXT NOT NULL
    )
    """)

    execute!(connection, """
    CREATE TABLE IF NOT EXISTS events (
      sequence INTEGER PRIMARY KEY,
      event_id TEXT NOT NULL UNIQUE,
      transaction_id TEXT NOT NULL REFERENCES transactions(id),
      schema_version INTEGER NOT NULL,
      type TEXT NOT NULL,
      aggregate_type TEXT NOT NULL,
      aggregate_id TEXT NOT NULL,
      room_id TEXT,
      correlation_id TEXT,
      causation_id TEXT,
      recorded_at TEXT NOT NULL,
      payload TEXT NOT NULL
    )
    """)

    execute!(
      connection,
      "CREATE INDEX IF NOT EXISTS events_type_sequence ON events(type, sequence)"
    )

    execute!(
      connection,
      "CREATE INDEX IF NOT EXISTS events_room_sequence ON events(room_id, sequence)"
    )

    execute!(connection, """
    CREATE TABLE IF NOT EXISTS checkpoints (
      sequence INTEGER PRIMARY KEY REFERENCES events(sequence),
      projection_version INTEGER NOT NULL,
      payload TEXT NOT NULL,
      checksum TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """)

    execute!(connection, """
    CREATE TABLE IF NOT EXISTS store_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """)
  end

  defp commit_entries(state, entries, transaction_id, expected_sequence) do
    connection = state.connection

    operation = fn ->
      commit_transaction(connection, entries, transaction_id, expected_sequence)
    end

    case transaction(connection, operation) do
      {:ok, events} -> {:ok, events, %{state | sequence: List.last(events).sequence}}
      {:error, {:conflict, actual}} -> {:error, {:conflict, actual}, %{state | sequence: actual}}
      {:error, reason} -> {:error, {:not_committed, reason}, state}
    end
  end

  defp commit_transaction(connection, entries, transaction_id, expected_sequence) do
    actual_sequence = scalar!(connection, "SELECT COALESCE(MAX(sequence), 0) FROM events")

    if actual_sequence != expected_sequence do
      throw({:conflict, actual_sequence})
    end

    events = build_events(entries, actual_sequence)
    insert_transaction(connection, transaction_id, events)
    Enum.each(events, &insert_event(connection, transaction_id, &1))
    events
  end

  defp build_events(entries, actual_sequence) do
    entries
    |> Enum.with_index(actual_sequence + 1)
    |> Enum.map(fn {{type, data, metadata}, sequence} ->
      Event.new(sequence, type, data, metadata)
    end)
  end

  defp insert_transaction(connection, transaction_id, events) do
    first = hd(events)
    last = List.last(events)

    run!(
      connection,
      """
      INSERT INTO transactions(id, first_sequence, last_sequence, event_count, committed_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [transaction_id, first.sequence, last.sequence, length(events), now()]
    )
  end

  defp insert_event(connection, transaction_id, event) do
    run!(
      connection,
      """
      INSERT INTO events(
        sequence, event_id, transaction_id, schema_version, type, aggregate_type,
        aggregate_id, room_id, correlation_id, causation_id, recorded_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        event.sequence,
        event.id,
        transaction_id,
        event.schema_version,
        Atom.to_string(event.type),
        Atom.to_string(event.aggregate_type),
        event.aggregate_id,
        event.room_id,
        event.correlation_id,
        event.causation_id,
        event.recorded_at,
        Event.encode!(event)
      ]
    )
  end

  defp transaction_events(connection, transaction_id) do
    connection
    |> rows(
      "SELECT payload FROM events WHERE transaction_id = ? ORDER BY sequence",
      [transaction_id]
    )
    |> Enum.map(fn [payload] -> Event.decode!(payload) end)
  end

  defp transaction(connection, operation) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE") do
      try do
        result = operation.()

        case execute(connection, "COMMIT") do
          :ok -> if(result == :ok, do: :ok, else: {:ok, result})
          {:error, reason} -> {:error, {:commit_unknown, reason}}
        end
      rescue
        error ->
          stacktrace = __STACKTRACE__
          _ = execute(connection, "ROLLBACK")
          reraise error, stacktrace
      catch
        {:conflict, actual} ->
          rollback(connection, {:conflict, actual})
      end
    end
  end

  defp rollback(connection, failure) do
    case execute(connection, "ROLLBACK") do
      :ok -> {:error, failure}
      {:error, reason} -> {:error, {:rollback_failed, failure, reason}}
    end
  end

  defp checkpoint(connection) do
    case rows(connection, "PRAGMA wal_checkpoint(FULL)") do
      [[0, _pages, _checkpointed]] -> :ok
      result -> {:error, {:checkpoint_failed, result}}
    end
  end

  defp vacuum_into(connection, destination) do
    escaped = String.replace(destination, "'", "''")
    execute(connection, "VACUUM INTO '#{escaped}'")
  end

  defp verify_file(path) do
    case verify_path(path) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, {:backup_integrity_check_failed, reason}}
    end
  end

  defp verify_connection(connection) do
    with [["ok"]] <- rows(connection, "PRAGMA quick_check"),
         [] <- rows(connection, "PRAGMA foreign_key_check") do
      :ok
    else
      result -> {:error, {:integrity_check_failed, result}}
    end
  end

  defp write_manifest(destination, sequence) do
    with {:ok, digest} <- Hashing.file_sha256_hex(destination) do
      manifest = %{
        database: destination,
        sequence: sequence,
        schema_version: @schema_version,
        sha256: digest,
        created_at: now()
      }

      manifest_path = destination <> ".manifest.json"

      with :ok <- File.write(manifest_path, Jason.encode!(manifest, pretty: true)),
           :ok <- File.chmod(manifest_path, 0o600) do
        {:ok, Map.put(manifest, :manifest, manifest_path)}
      end
    end
  end

  defp secure_files(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.filter(&File.exists?/1)
    |> Enum.each(&File.chmod!(&1, 0o600))
  end

  defp scalar(connection, sql) do
    case rows(connection, sql) do
      [[value]] -> {:ok, value}
      result -> {:error, {:unexpected_query_result, result}}
    end
  end

  defp scalar!(connection, sql) do
    {:ok, value} = scalar(connection, sql)
    value
  end

  defp rows(connection, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(connection, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(connection, statement)
      rows
    after
      Sqlite3.release(connection, statement)
    end
  end

  defp run!(connection, sql, params) do
    {:ok, statement} = Sqlite3.prepare(connection, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      :done = Sqlite3.step(connection, statement)
      :ok
    after
      Sqlite3.release(connection, statement)
    end
  end

  defp execute(connection, sql), do: Sqlite3.execute(connection, sql)

  defp execute!(connection, sql) do
    :ok = execute(connection, sql)
  end

  defp transaction_id do
    "tx-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
