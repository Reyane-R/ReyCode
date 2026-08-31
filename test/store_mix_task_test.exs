defmodule ReyCode.StoreMixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReyCode.Store, as: StoreTask
  alias ReyCode.{EventStore, Orchestration}

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "rey_code_store_task_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, directory: directory}
  end

  test "verifies a store and prints a JSON report", %{directory: directory} do
    path = seed_store(Path.join(directory, "events.sqlite3"))

    output = capture_io(fn -> StoreTask.run(["verify", "--path", path]) end)

    assert output =~ "\"backend\": \"sqlite\""
    assert output =~ "\"sequence\": 1"
  end

  test "checkpoints the projection and reports the sequence", %{directory: directory} do
    path = seed_store(Path.join(directory, "events.sqlite3"))

    output = capture_io(fn -> StoreTask.run(["checkpoint", "--path", path]) end)

    assert output =~ "\"sequence\": 1"
  end

  test "backs up a store to a destination with its manifest", %{directory: directory} do
    path = seed_store(Path.join(directory, "events.sqlite3"))
    destination = Path.join(directory, "backup.sqlite3")

    output = capture_io(fn -> StoreTask.run(["backup", destination, "--path", path]) end)

    assert output =~ "\"sequence\": 1"
    assert File.exists?(destination)
    assert File.exists?(destination <> ".manifest.json")
  end

  test "restores a backup into a fresh or replaced destination", %{directory: directory} do
    path = seed_store(Path.join(directory, "events.sqlite3"))
    backup = Path.join(directory, "backup.sqlite3")
    capture_io(fn -> StoreTask.run(["backup", backup, "--path", path]) end)

    destination = Path.join(directory, "restored.sqlite3")
    output = capture_io(fn -> StoreTask.run(["restore", backup, "--path", destination]) end)

    assert output =~ "\"sequence\": 1"
    assert File.exists?(destination)

    replaced =
      capture_io(fn ->
        StoreTask.run(["restore", backup, "--path", destination, "--replace"])
      end)

    assert replaced =~ "\"sequence\": 1"
  end

  test "raises usage on unknown operations or invalid flags", %{directory: directory} do
    assert_raise Mix.Error, ~r/Usage: mix rey_code\.store/, fn ->
      StoreTask.run(["frobnicate", "--path", Path.join(directory, "unused.sqlite3")])
    end

    assert_raise Mix.Error, ~r/Usage: mix rey_code\.store/, fn ->
      StoreTask.run(["verify", "--bogus", "1"])
    end
  end

  # A store init failure stops the GenServer abnormally, and the abnormal
  # EXIT can reach this process before the {:error, reason} reply. Trap
  # exits around the start so a failure surfaces as a tagged result.
  defp open_store(path) do
    Process.flag(:trap_exit, true)
    result = EventStore.start_link(name: nil, path: path)

    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, false)
    result
  end

  test "raises when the source is missing or the destination is occupied", %{directory: directory} do
    missing = Path.join(directory, "missing.sqlite3")

    assert_raise Mix.Error, ~r/Store operation failed/, fn ->
      StoreTask.run(["verify", "--path", missing])
    end

    path = seed_store(Path.join(directory, "events.sqlite3"))
    occupied = seed_store(Path.join(directory, "occupied.sqlite3"))

    assert_raise Mix.Error, ~r/Store operation failed/, fn ->
      StoreTask.run(["restore", path, "--path", occupied])
    end
  end

  defp seed_store(path) do
    {:ok, store} = open_store(path)
    assert {:ok, [_event]} = EventStore.append_many([session_entry()], store)
    GenServer.stop(store)

    path
  end

  defp session_entry do
    Orchestration.EventEntries.session_created(
      "room-store-task",
      "store-task",
      "Store Task",
      File.cwd!(),
      [
        %{
          "id" => "assistant",
          "name" => "Assistant",
          "perspective" => "general coding assistance",
          "model" => nil,
          "kind" => "primary",
          "provider" => "simulator"
        }
      ]
    )
  end
end
