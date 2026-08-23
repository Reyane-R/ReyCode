defmodule ReyCode.EventStore.SQLite.Migrations do
  @moduledoc """
  Versioned schema migrations for the SQLite event store.

  Owns the migration list, the `schema_migrations` bookkeeping table,
  future-version rejection, and transactional application of pending DDL.
  """

  alias ReyCode.EventStore.SQLite.Sql

  @migrations [{1, :create_initial_schema}]
  @schema_version @migrations |> List.last() |> elem(0)

  @doc "Returns the highest schema version this build understands."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Creates the migration bookkeeping table when absent."
  @spec ensure_table(term()) :: :ok | {:error, term()}
  def ensure_table(connection) do
    Sql.transaction(connection, fn ->
      Sql.execute!(connection, """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
      """)
    end)
  end

  @doc "Returns already-applied versions in ascending order."
  @spec applied_versions(term()) :: [pos_integer()]
  def applied_versions(connection) do
    connection
    |> Sql.rows("SELECT version FROM schema_migrations ORDER BY version")
    |> Enum.map(fn [version] -> version end)
  end

  @doc "Rejects databases migrated beyond this build's schema version."
  @spec validate_versions([pos_integer()]) :: :ok | {:error, term()}
  def validate_versions(versions) do
    case Enum.find(versions, &(&1 > @schema_version)) do
      nil -> :ok
      version -> {:error, {:unsupported_schema_version, version, @schema_version}}
    end
  end

  @doc "Applies every not-yet-applied migration inside one transaction."
  @spec apply_pending(term(), [pos_integer()]) :: :ok | {:error, term()}
  def apply_pending(connection, applied_versions) do
    pending = Enum.reject(@migrations, fn {version, _name} -> version in applied_versions end)

    Sql.transaction(connection, fn ->
      Enum.each(pending, fn {version, name} ->
        apply_migration(connection, name)

        Sql.run!(
          connection,
          "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
          [version, Sql.now()]
        )
      end)
    end)
  end

  defp apply_migration(connection, :create_initial_schema) do
    Sql.execute!(connection, """
    CREATE TABLE IF NOT EXISTS transactions (
      id TEXT PRIMARY KEY,
      first_sequence INTEGER NOT NULL,
      last_sequence INTEGER NOT NULL,
      event_count INTEGER NOT NULL CHECK (event_count > 0),
      committed_at TEXT NOT NULL
    )
    """)

    Sql.execute!(connection, """
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

    Sql.execute!(
      connection,
      "CREATE INDEX IF NOT EXISTS events_type_sequence ON events(type, sequence)"
    )

    Sql.execute!(
      connection,
      "CREATE INDEX IF NOT EXISTS events_room_sequence ON events(room_id, sequence)"
    )

    Sql.execute!(connection, """
    CREATE TABLE IF NOT EXISTS checkpoints (
      sequence INTEGER PRIMARY KEY REFERENCES events(sequence),
      projection_version INTEGER NOT NULL,
      payload TEXT NOT NULL,
      checksum TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """)

    Sql.execute!(connection, """
    CREATE TABLE IF NOT EXISTS store_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """)
  end
end
