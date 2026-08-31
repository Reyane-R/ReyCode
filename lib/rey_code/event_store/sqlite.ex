defmodule ReyCode.EventStore.SQLite do
  @moduledoc """
  The SQLite event-store adapter.

  This facade owns connection lifecycle and PRAGMA policy and composes the
  cohesive internals: `SQLite.Sql` (statement/transaction primitives),
  `SQLite.Migrations` (versioned DDL), `SQLite.Checkpoint` (pure codec),
  and `SQLite.Backup` (integrity/VACUUM/manifests).
  """

  alias Exqlite.Sqlite3
  alias ReyCode.{Event, Hashing}
  alias ReyCode.EventStore.SQLite.{Backup, Checkpoint, Migrations, Sql}

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

  def close(%{connection: connection}), do: Sqlite3.close(connection)

  @doc """
  Whether an open/PRAGMA failure means another process holds the store.

  Exqlite surfaces SQLite busy states as `"database is locked"` binaries or
  `:busy`/`:locked` atoms; the store's EXCLUSIVE locking mode turns any
  concurrent holder into one of these.
  """
  @spec database_locked?(term()) :: boolean()
  def database_locked?(:busy), do: true
  def database_locked?(:locked), do: true

  def database_locked?(reason) when is_binary(reason),
    do: String.contains?(String.downcase(reason), ["locked", "busy"])

  def database_locked?(_reason), do: false

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
    |> Sql.rows(sql)
    |> Enum.map(fn [payload] -> Event.decode!(payload) end)
  end

  def load_projection(%{connection: connection}, replay_limit, max_checkpoint_bytes) do
    case Sql.rows(connection, """
         SELECT sequence, projection_version, payload, checksum
         FROM checkpoints
         ORDER BY sequence DESC
         LIMIT 1
         """) do
      [] ->
        recover_tail(connection, nil, 0, replay_limit)

      [[sequence, version, payload, checksum]] ->
        with {:ok, projection} <-
               Checkpoint.decode(payload, version, sequence, checksum, max_checkpoint_bytes) do
          recover_tail(connection, projection, sequence, replay_limit)
        end
    end
  end

  # A tail longer than the replay limit means the newest checkpoint is too
  # stale (or absent) to resume from. The event log itself is intact, so fall
  # back to one full replay instead of making startup impossible. The replay
  # starts at the same schema-v2 snapshot barrier load/1 uses, so retired
  # event types before the barrier are never decoded.
  defp recover_tail(connection, projection, sequence, replay_limit) do
    case load_projection_tail(connection, projection, sequence, replay_limit) do
      {:error, {:replay_limit_exceeded, _, _}} ->
        rows =
          Sql.rows(connection, """
          SELECT payload FROM events
          WHERE sequence >= COALESCE(
            (SELECT MAX(sequence) FROM events WHERE type = 'snapshot_recorded'),
            1
          )
          ORDER BY sequence
          """)

        {:ok, nil, decode_events(rows)}

      result ->
        result
    end
  end

  defp decode_events(rows), do: Enum.map(rows, fn [payload] -> Event.decode!(payload) end)

  def checkpoint(%{connection: connection, sequence: store_sequence}, projection, max_bytes) do
    sequence = projection[:sequence]
    payload = projection |> Checkpoint.encode_term() |> Jason.encode!()

    cond do
      not is_integer(sequence) or sequence <= 0 or sequence > store_sequence ->
        {:error, :invalid_checkpoint_sequence}

      byte_size(payload) > max_bytes ->
        {:error, {:checkpoint_too_large, byte_size(payload), max_bytes}}

      true ->
        persist_checkpoint(connection, sequence, payload)
    end
  end

  def append_many(state, entries, opts) do
    # Malformed payloads fail closed before the durable boundary: no
    # transaction opens and no row is written when any entry is invalid.
    with :ok <- Event.validate_entries(entries) do
      transaction_id = Keyword.get_lazy(opts, :transaction_id, &Sql.transaction_id/0)
      expected_sequence = Keyword.get(opts, :expected_sequence, state.sequence)

      case transaction_events(state.connection, transaction_id) do
        [] -> commit_entries(state, entries, transaction_id, expected_sequence)
        events -> {:ok, events, state}
      end
    end
  end

  def import_events(state, []), do: {:ok, state}

  def import_events(%{sequence: 0} = state, events) do
    transaction_id = "legacy-ndjson-v2-import"
    connection = state.connection

    case Sql.transaction(connection, fn ->
           insert_transaction(connection, transaction_id, events)
           Enum.each(events, &insert_event(connection, transaction_id, &1))

           Sql.execute!(
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
    with :ok <- Backup.verify_connection(connection) do
      {:ok, %{backend: :sqlite, path: path, sequence: sequence}}
    end
  end

  def verify_path(path), do: Backup.verify_path(path)

  def backup(%{connection: connection, sequence: sequence}, destination),
    do: Backup.backup(connection, sequence, destination)

  defp initialize(connection, path) do
    result =
      with :ok <- configure(connection),
           :ok <- Migrations.ensure_table(connection),
           applied <- Migrations.applied_versions(connection),
           :ok <- Migrations.validate_versions(applied),
           :ok <- Migrations.apply_pending(connection, applied),
           {:ok, sequence} <-
             Sql.scalar(connection, "SELECT COALESCE(MAX(sequence), 0) FROM events") do
        secure_files(path)
        {:ok, %{backend: :sqlite, path: path, connection: connection, sequence: sequence}}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        _ = Sqlite3.close(connection)

        if database_locked?(reason),
          do: {:error, {:database_locked, path}},
          else: {:error, reason}
    end
  rescue
    error ->
      stacktrace = __STACKTRACE__
      _ = Sqlite3.close(connection)
      reraise error, stacktrace
  end

  defp ensure_directory(directory) do
    directory_exists = File.dir?(directory)

    case File.mkdir_p(directory) do
      :ok -> maybe_harden_new_directory(directory, directory_exists)
      error -> error
    end
  end

  defp maybe_harden_new_directory(_directory, true), do: :ok
  defp maybe_harden_new_directory(directory, false), do: File.chmod(directory, 0o700)

  defp configure(connection) do
    with :ok <- Sqlite3.set_busy_timeout(connection, 5_000),
         :ok <- Sql.execute(connection, "PRAGMA locking_mode=EXCLUSIVE"),
         :ok <- Sql.execute(connection, "PRAGMA journal_mode=WAL"),
         :ok <- Sql.execute(connection, "PRAGMA synchronous=FULL"),
         :ok <- Sql.execute(connection, "PRAGMA fullfsync=ON"),
         :ok <- Sql.execute(connection, "PRAGMA checkpoint_fullfsync=ON"),
         :ok <- Sql.execute(connection, "PRAGMA foreign_keys=ON"),
         :ok <- Sql.execute(connection, "PRAGMA trusted_schema=OFF"),
         :ok <- Sql.execute(connection, "PRAGMA journal_size_limit=16777216"),
         {:ok, version} <- Sql.scalar(connection, "SELECT sqlite_version()"),
         :ok <- validate_sqlite_version(version),
         {:ok, "wal"} <- Sql.scalar(connection, "PRAGMA journal_mode") do
      :ok
    end
  end

  defp validate_sqlite_version(version) do
    minimum = Version.parse!("3.51.3")

    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, minimum) == :lt,
          do: {:error, {:unsupported_sqlite, version}},
          else: :ok

      :error ->
        {:error, {:invalid_sqlite_version, version}}
    end
  end

  defp persist_checkpoint(connection, sequence, payload) do
    checksum = Hashing.sha256_hex(payload)
    retention = Checkpoint.retention()

    Sql.transaction(connection, fn ->
      Sql.run!(
        connection,
        """
        INSERT OR REPLACE INTO checkpoints(
          sequence, projection_version, payload, checksum, created_at
        ) VALUES (?, ?, ?, ?, ?)
        """,
        [sequence, Checkpoint.projection_version(), payload, checksum, Sql.now()]
      )

      Sql.execute!(connection, """
      DELETE FROM checkpoints
      WHERE sequence NOT IN (
        SELECT sequence FROM checkpoints ORDER BY sequence DESC LIMIT #{retention}
      )
      """)
    end)
  end

  defp load_projection_tail(connection, projection, sequence, replay_limit) do
    event_rows =
      Sql.rows(
        connection,
        "SELECT payload FROM events WHERE sequence > ? ORDER BY sequence LIMIT ?",
        [sequence, replay_limit + 1]
      )

    if length(event_rows) > replay_limit do
      {:error, {:replay_limit_exceeded, sequence, replay_limit}}
    else
      {:ok, projection, decode_events(event_rows)}
    end
  end

  defp commit_entries(state, entries, transaction_id, expected_sequence) do
    connection = state.connection

    operation = fn ->
      commit_transaction(connection, entries, transaction_id, expected_sequence)
    end

    case Sql.transaction(connection, operation) do
      {:ok, events} -> {:ok, events, %{state | sequence: List.last(events).sequence}}
      {:error, {:conflict, actual}} -> {:error, {:conflict, actual}, %{state | sequence: actual}}
      {:error, reason} -> {:error, {:not_committed, reason}, state}
    end
  end

  defp commit_transaction(connection, entries, transaction_id, expected_sequence) do
    actual_sequence = Sql.scalar!(connection, "SELECT COALESCE(MAX(sequence), 0) FROM events")

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

    Sql.run!(
      connection,
      """
      INSERT INTO transactions(id, first_sequence, last_sequence, event_count, committed_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [transaction_id, first.sequence, last.sequence, length(events), Sql.now()]
    )
  end

  defp insert_event(connection, transaction_id, event) do
    Sql.run!(
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
    |> Sql.rows("SELECT payload FROM events WHERE transaction_id = ? ORDER BY sequence", [
      transaction_id
    ])
    |> Enum.map(fn [payload] -> Event.decode!(payload) end)
  end

  defp secure_files(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.filter(&File.exists?/1)
    |> Enum.each(&File.chmod!(&1, 0o600))
  end
end
