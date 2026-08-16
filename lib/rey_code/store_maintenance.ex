defmodule ReyCode.StoreMaintenance do
  @moduledoc "Offline verification, backup, and restore operations for the event store."

  alias ReyCode.{EventStore, Hashing}
  alias ReyCode.EventStore.SQLite
  alias ReyCode.Orchestration.Projector

  @spec verify(Path.t()) :: {:ok, map()} | {:error, term()}
  def verify(path), do: with_store(path, &EventStore.verify/1)

  @spec backup(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def backup(source, destination) do
    with_store(source, &EventStore.backup(destination, &1))
  end

  @spec checkpoint(Path.t()) :: {:ok, map()} | {:error, term()}
  def checkpoint(path) do
    with_store(path, fn store ->
      projection = store |> EventStore.load() |> Projector.replay()

      case EventStore.checkpoint(projection, store) do
        :ok -> {:ok, %{path: Path.expand(path), sequence: projection.sequence}}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec restore(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore(source, destination, opts \\ []) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    with :ok <- require_replace(destination, opts[:replace]),
         :ok <- verify_manifest(source),
         {:ok, source_report} <- SQLite.verify_path(source),
         :ok <- ensure_destination_offline(destination),
         :ok <- install_copy(source, destination),
         {:ok, restored_report} <- SQLite.verify_path(destination) do
      {:ok,
       %{
         source: source,
         destination: destination,
         sequence: restored_report.sequence,
         backend: source_report.backend
       }}
    end
  end

  defp with_store(path, operation) do
    path = Path.expand(path)

    with {:ok, _applications} <- Application.ensure_all_started(:exqlite),
         {:ok, store} <- EventStore.start_link(name: nil, path: path) do
      try do
        operation.(store)
      after
        GenServer.stop(store)
      end
    end
  end

  defp require_replace(destination, true), do: ensure_sqlite_destination(destination)

  defp require_replace(destination, _replace) do
    if File.exists?(destination),
      do: {:error, :destination_exists},
      else: ensure_sqlite_destination(destination)
  end

  defp ensure_sqlite_destination(path) do
    if Path.extname(path) in [".db", ".sqlite", ".sqlite3"],
      do: :ok,
      else: {:error, :restore_requires_sqlite_destination}
  end

  defp verify_manifest(source) do
    manifest_path = source <> ".manifest.json"

    with {:ok, payload} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(payload),
         expected when is_binary(expected) <- manifest["sha256"],
         {:ok, actual} <- hash_source(source) do
      if secure_compare(expected, actual), do: :ok, else: {:error, :backup_checksum_mismatch}
    else
      {:error, :enoent} -> {:error, :backup_manifest_missing}
      {:error, {:source_unreadable, _}} = error -> error
      {:error, reason} -> {:error, {:invalid_backup_manifest, reason}}
      nil -> {:error, :backup_manifest_missing_sha256}
    end
  end

  defp hash_source(source) do
    case Hashing.file_sha256_hex(source) do
      {:ok, hex} -> {:ok, hex}
      {:error, reason} -> {:error, {:source_unreadable, reason}}
    end
  end

  defp ensure_destination_offline(destination) do
    ownership_key = {EventStore, destination}

    cond do
      :global.whereis_name(ownership_key) != :undefined ->
        {:error, :destination_in_use}

      not File.exists?(destination) ->
        :ok

      true ->
        probe_destination(destination)
    end
  end

  defp probe_destination(destination) do
    case with_store(destination, fn _store -> :ok end) do
      :ok -> :ok
      {:error, reason} -> {:error, {:destination_unavailable, reason}}
    end
  end

  defp install_copy(source, destination) do
    directory = Path.dirname(destination)

    temporary =
      destination <> ".restore-#{System.unique_integer([:positive, :monotonic])}.sqlite3"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, _bytes} <- File.copy(source, temporary),
         :ok <- File.chmod(temporary, 0o600),
         {:ok, _report} <- SQLite.verify_path(temporary),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      error ->
        _ = File.rm(temporary)
        error
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {x, y}, result -> Bitwise.bor(result, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false
end
