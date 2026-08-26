defmodule ReyCode.ApplicationBootTest do
  # The single deliberate global-boundary test: proves the production
  # application boots its named stack. Every other integration suite starts
  # its own isolated runtime.
  use ExUnit.Case, async: false

  test "boots the globally named EventStore, Catalog, and Engine stack" do
    assert is_pid(Process.whereis(ReyCode.EventStore))
    assert is_pid(Process.whereis(ReyCode.Provider.Catalog))
    assert is_pid(Process.whereis(ReyCode.Supervisor))
    assert %ReyCode.Orchestration.Projection{} = ReyCode.snapshot()
  end

  test "storage_paths honors data_dir override and legacy XDG location" do
    previous_event_path = Application.get_env(:rey_code, :event_path)
    previous_data_dir = Application.get_env(:rey_code, :data_dir)

    try do
      Application.delete_env(:rey_code, :event_path)
      Application.put_env(:rey_code, :data_dir, "/tmp/rey_code_data_test")

      paths = ReyCode.Application.storage_paths()

      assert paths.database == "/tmp/rey_code_data_test/rey_code.sqlite3"

      assert paths.legacy ==
               Path.join([
                 System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
                 "rey_code",
                 "events-v2.ndjson"
               ])
    after
      restore_env(:event_path, previous_event_path)
      restore_env(:data_dir, previous_data_dir)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:rey_code, key)
  defp restore_env(key, value), do: Application.put_env(:rey_code, key, value)
end
