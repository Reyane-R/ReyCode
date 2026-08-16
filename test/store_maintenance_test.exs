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
