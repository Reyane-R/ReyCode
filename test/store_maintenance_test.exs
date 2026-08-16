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

  defp start_store(path) do
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
