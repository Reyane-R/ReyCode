defmodule ReyCode.EventStore.SQLite.Backup do
  @moduledoc """
  Integrity verification, WAL checkpointing, VACUUM-based backups, and
  manifest creation for the SQLite event store.
  """

  alias Exqlite.Sqlite3
  alias ReyCode.EventStore.SQLite.Migrations
  alias ReyCode.EventStore.SQLite.Sql
  alias ReyCode.Hashing

  @doc "Runs quick_check and foreign_key_check against an open connection."
  @spec verify_connection(term()) :: :ok | {:error, term()}
  def verify_connection(connection) do
    with [["ok"]] <- Sql.rows(connection, "PRAGMA quick_check"),
         [] <- Sql.rows(connection, "PRAGMA foreign_key_check") do
      :ok
    else
      result -> {:error, {:integrity_check_failed, result}}
    end
  end

  @doc "Verifies a database file by opening it read-only."
  @spec verify_path(Path.t()) :: {:ok, map()} | {:error, term()}
  def verify_path(path) do
    path = Path.expand(path)

    with {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
      try do
        with :ok <- verify_connection(connection),
             {:ok, sequence} <-
               Sql.scalar(connection, "SELECT COALESCE(MAX(sequence), 0) FROM events") do
          {:ok, %{backend: :sqlite, path: path, sequence: sequence}}
        end
      rescue
        error -> {:error, {:integrity_check_failed, Exception.message(error)}}
      after
        Sqlite3.close(connection)
      end
    end
  end

  @doc "Creates a consistent owner-only backup plus its manifest."
  @spec backup(term(), pos_integer(), Path.t()) :: {:ok, map()} | {:error, term()}
  def backup(connection, sequence, destination) do
    destination = Path.expand(destination)
    suffix = System.unique_integer([:positive])
    temporary_database = destination <> ".tmp-#{suffix}"
    manifest_path = destination <> ".manifest.json"
    temporary_manifest = manifest_path <> ".tmp-#{suffix}"

    if File.exists?(destination) or File.exists?(manifest_path) do
      {:error, :destination_exists}
    else
      result =
        with :ok <- File.mkdir_p(Path.dirname(destination)),
             :ok <- wal_checkpoint(connection),
             :ok <- vacuum_into(connection, temporary_database),
             :ok <- File.chmod(temporary_database, 0o600),
             :ok <- verify_backup(temporary_database),
             {:ok, manifest} <- manifest(temporary_database, destination, sequence),
             :ok <- File.write(temporary_manifest, Jason.encode!(manifest, pretty: true)),
             :ok <- File.chmod(temporary_manifest, 0o600),
             :ok <-
               publish_backup(temporary_database, destination, temporary_manifest, manifest_path) do
          {:ok, Map.put(manifest, :manifest, manifest_path)}
        end

      if match?({:error, _reason}, result) do
        Enum.each([temporary_database, temporary_manifest], &File.rm/1)
      end

      result
    end
  end

  @doc "Writes the sidecar manifest describing a completed backup."
  @spec write_manifest(Path.t(), pos_integer(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def write_manifest(destination, sequence, schema_version \\ Migrations.schema_version()) do
    with {:ok, manifest} <- manifest(destination, destination, sequence, schema_version) do
      manifest_path = destination <> ".manifest.json"

      with :ok <- File.write(manifest_path, Jason.encode!(manifest, pretty: true)),
           :ok <- File.chmod(manifest_path, 0o600) do
        {:ok, Map.put(manifest, :manifest, manifest_path)}
      end
    end
  end

  defp manifest(source, destination, sequence, schema_version \\ Migrations.schema_version()) do
    with {:ok, digest} <- Hashing.file_sha256_hex(source) do
      {:ok,
       %{
         database: destination,
         sequence: sequence,
         schema_version: schema_version,
         sha256: digest,
         created_at: Sql.now()
       }}
    end
  end

  defp publish_backup(temporary_database, destination, temporary_manifest, manifest_path) do
    case publish_file(temporary_database, destination) do
      :ok -> publish_manifest(temporary_manifest, manifest_path, destination)
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_manifest(temporary_manifest, manifest_path, destination) do
    case publish_file(temporary_manifest, manifest_path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(destination)
        {:error, reason}
    end
  end

  # A hard link publishes without replacing a file created by a competing backup.
  defp publish_file(temporary, destination) do
    case File.ln(temporary, destination) do
      :ok ->
        File.rm(temporary)
        :ok

      {:error, :eexist} ->
        {:error, :destination_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wal_checkpoint(connection) do
    case Sql.rows(connection, "PRAGMA wal_checkpoint(FULL)") do
      [[0, _pages, _checkpointed]] -> :ok
      result -> {:error, {:checkpoint_failed, result}}
    end
  end

  defp vacuum_into(connection, destination) do
    escaped = String.replace(destination, "'", "''")
    Sql.execute(connection, "VACUUM INTO '#{escaped}'")
  end

  defp verify_backup(destination) do
    case verify_path(destination) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, {:backup_integrity_check_failed, reason}}
    end
  end
end
