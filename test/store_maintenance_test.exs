defmodule ReyCode.StoreMaintenanceTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, StoreMaintenance}

  test "restores a verified backup and requires explicit replacement" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    restored = tmp_path("restored.sqlite3")
    {store, id} = start_store(source)

    assert {:ok, event} = EventStore.append(:room_created, room_data(), store, metadata())
    assert {:ok, _manifest} = EventStore.backup(backup, store)
    stop_supervised!(id)

    assert {:ok, %{sequence: 1}} = StoreMaintenance.restore(backup, restored)
    assert {:error, :destination_exists} = StoreMaintenance.restore(backup, restored)
    assert {:ok, %{sequence: 1}} = StoreMaintenance.restore(backup, restored, replace: true)

    {restored_store, _id} = start_store(restored)
    assert EventStore.load(restored_store) == [event]
  end

  test "restore preserves an existing parent directory's permissions" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    parent = tmp_path("kept-parent")
    restored = Path.join(parent, "restored.sqlite3")
    {store, id} = start_store(source)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())
    assert {:ok, _manifest} = EventStore.backup(backup, store)
    stop_supervised!(id)

    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)

    assert {:ok, %{sequence: 1}} = StoreMaintenance.restore(backup, restored)

    assert {:ok, %File.Stat{} = stat} = File.stat(parent)
    assert Bitwise.band(stat.mode, 0o777) == 0o755
  end

  test "detects a live destination store through a symlink alias" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    destination = tmp_path("destination.sqlite3")
    alias_path = tmp_path("destination-alias.sqlite3")
    {source_store, _source_id} = start_store(source)
    {_destination_store, _destination_id} = start_store(destination)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), source_store, metadata())
    assert {:ok, _manifest} = EventStore.backup(backup, source_store)
    File.mkdir_p!(Path.dirname(alias_path))
    File.ln_s!(destination, alias_path)

    assert {:error, :destination_in_use} =
             StoreMaintenance.restore(backup, alias_path, replace: true)
  end

  test "rejects missing and mismatched backup manifests" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    restored = tmp_path("restored.sqlite3")
    {store, _id} = start_store(source)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())
    assert {:ok, _manifest} = EventStore.backup(backup, store)

    File.rm!(backup <> ".manifest.json")
    assert {:error, :backup_manifest_missing} = StoreMaintenance.restore(backup, restored)

    File.write!(backup <> ".manifest.json", ~s({"sha256":"#{String.duplicate("0", 64)}"}))
    assert {:error, :backup_checksum_mismatch} = StoreMaintenance.restore(backup, restored)
  end

  test "distinguishes a missing source store from a missing manifest" do
    vanished = tmp_path("vanished.sqlite3")
    destination = tmp_path("vanished_restored.sqlite3")

    File.mkdir_p!(Path.dirname(vanished))
    File.write!(vanished <> ".manifest.json", ~s({"sha256":"#{String.duplicate("a", 64)}"}))

    on_exit(fn ->
      File.rm(vanished <> ".manifest.json")
      File.rm(destination)
    end)

    assert {:error, {:source_unreadable, :enoent}} =
             StoreMaintenance.restore(vanished, destination, replace: true)

    refute File.exists?(destination)

    orphan_manifest = tmp_path("orphan.sqlite3")

    assert {:error, :backup_manifest_missing} =
             StoreMaintenance.restore(orphan_manifest, destination, replace: true)
  end

  test "maintenance commands reject missing and directory sources without creating them" do
    missing = tmp_path("missing.sqlite3")
    backup = tmp_path("missing-backup.sqlite3")
    directory = tmp_path("source-directory")
    File.mkdir_p!(directory)

    assert {:error, :source_not_found} = StoreMaintenance.verify(missing)
    assert {:error, :source_not_found} = StoreMaintenance.backup(missing, backup)
    assert {:error, :source_not_found} = StoreMaintenance.checkpoint(missing)
    refute File.exists?(missing)
    refute File.exists?(backup)

    assert {:error, :source_not_a_store} = StoreMaintenance.verify(directory)
    assert {:error, :source_not_a_store} = StoreMaintenance.backup(directory, backup)
    assert {:error, :source_not_a_store} = StoreMaintenance.checkpoint(directory)
  end

  test "failed backup publication removes partial files so a retry can succeed" do
    source = tmp_path("retry-source.sqlite3")
    backup = tmp_path("retry-backup.sqlite3")
    {store, _id} = start_store(source)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())
    File.mkdir_p!(backup <> ".manifest.json")

    assert {:error, :destination_exists} = EventStore.backup(backup, store)
    refute File.exists?(backup)

    File.rmdir!(backup <> ".manifest.json")
    assert {:ok, _manifest} = EventStore.backup(backup, store)
  end

  test "competing backup publishers cannot overwrite each other's artifacts" do
    source_a = tmp_path("concurrent-source-a.sqlite3")
    source_b = tmp_path("concurrent-source-b.sqlite3")
    backup = tmp_path("concurrent-backup.sqlite3")
    {store_a, _id_a} = start_store(source_a)
    {store_b, _id_b} = start_store(source_b)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store_a, metadata())

    assert {:ok, _event} =
             EventStore.append(
               :room_created,
               Map.put(room_data(), "title", "Competing source"),
               store_b,
               metadata()
             )

    tasks =
      Enum.map([store_a, store_b], fn store ->
        Task.async(fn -> EventStore.backup(backup, store) end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _manifest}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :destination_exists})) == 1
    assert {:ok, _report} = StoreMaintenance.verify(backup)
  end

  test "a manifest publish failure leaves no database behind and the retry completes" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    {store, id} = start_store(source)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())

    # Obstruct exactly the commit boundary: the manifest path is a directory.
    File.mkdir_p!(Path.dirname(backup))
    File.mkdir_p!(backup <> ".manifest.json")

    assert {:error, :destination_exists} = EventStore.backup(backup, store)
    refute File.exists?(backup), "failed attempt left the published database behind"

    File.rmdir!(backup <> ".manifest.json")

    assert {:ok, _manifest} = EventStore.backup(backup, store)
    assert {:ok, _report} = StoreMaintenance.verify(backup)

    stop_supervised!(id)
  end

  test "uncommitted residue from an interrupted backup is recoverable on retry" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    {store, id} = start_store(source)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())

    # Simulate a process death between publishing the database and the
    # manifest: destination exists without its commit marker.
    File.mkdir_p!(Path.dirname(backup))
    File.cp!(source, backup)

    assert {:ok, _manifest} = EventStore.backup(backup, store)
    assert {:ok, _report} = StoreMaintenance.verify(backup)

    stop_supervised!(id)
  end

  test "a committed backup still blocks overwriting" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    {store, id} = start_store(source)

    assert {:ok, _manifest} = EventStore.backup(backup, store)

    assert {:error, :destination_exists} = EventStore.backup(backup, store)

    stop_supervised!(id)
  end

  test "a failed attempt never deletes a destination that predated the call" do
    source = tmp_path("source.sqlite3")
    backup = tmp_path("backup.sqlite3")
    {store, id} = start_store(source)

    assert {:ok, _event} = EventStore.append(:room_created, room_data(), store, metadata())

    File.mkdir_p!(Path.dirname(backup))
    File.write!(backup, "predating user file")

    File.mkdir_p!(backup <> ".manifest.json")

    assert {:error, :destination_exists} = EventStore.backup(backup, store)
    assert File.read!(backup) == "predating user file"

    stop_supervised!(id)
  end

  defp start_store(path) do
    File.mkdir_p!(Path.dirname(path))
    id = {EventStore, System.unique_integer([:positive])}
    spec = Supervisor.child_spec({EventStore, name: nil, path: path}, id: id)
    {start_supervised!(spec), id}
  end

  defp room_data do
    %{
      "room_id" => "room-1",
      "slug" => "alpha",
      "title" => "Alpha",
      "workspace" => System.tmp_dir!(),
      "participants" => []
    }
  end

  defp metadata do
    [aggregate_type: :room, aggregate_id: "room-1", room_id: "room-1"]
  end

  defp tmp_path(filename) do
    Path.join(
      System.tmp_dir!(),
      "rey_code_maintenance_#{System.pid()}_#{System.unique_integer([:positive])}/#{filename}"
    )
  end
end
