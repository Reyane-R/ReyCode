defmodule ReyCode.Memory.StoreTest do
  use ExUnit.Case, async: true

  alias ReyCode.Memory.Store

  test "retains, recalls, invalidates, and recovers append-only memory" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey-code-memory-#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({Store, name: nil, path: path})
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{key: "build", kind: "retain"}} =
             Store.retain("project", "build", "Run mix check", ["quality"], store)

    assert {:ok, %{key: "lesson", kind: "learn"}} =
             Store.learn("project", "lesson", "Prefer bounded ports", [], store)

    assert {:ok, memories} = Store.recall("project", "bounded", 10, store)
    assert Enum.map(memories, & &1.key) == ["lesson"]
    assert {:ok, reflection} = Store.reflect("project", store)
    assert reflection.count == 2
    assert :ok = Store.forget("project", "lesson", store)
    assert {:ok, []} = Store.recall("project", "bounded", 10, store)
    :ok = GenServer.stop(store)
    {:ok, restarted} = Store.start_link(name: nil, path: path)
    assert {:ok, [memory]} = Store.recall("project", "check", 10, restarted)

    on_exit(fn ->
      if Process.alive?(restarted), do: GenServer.stop(restarted)
    end)

    assert memory.key == "build"
  end

  test "lists typed decisions and assumptions including invalidated current state" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey-code-memory-kinds-#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({Store, name: nil, path: path})
    on_exit(fn -> File.rm(path) end)

    assert Store.record_kinds() == ~w(decision assumption fact lesson)

    assert {:ok, decision} =
             Store.record(
               "project",
               "decision",
               "database",
               ~s({"statement":"Use SQLite","rationale":"single writer"}),
               ["decision"],
               store
             )

    assert decision.kind == "decision"

    assert {:ok, _assumption} =
             Store.record("project", "assumption", "runtime", "OTP 28", ["assumption"], store)

    assert {:error, :invalid_memory_kind} =
             Store.record("project", "unknown", "bad", "value", [], store)

    assert {:ok, [listed]} = Store.list("project", ["decision"], 10, store)
    assert listed.key == "database"
    assert listed.active

    assert :ok = Store.forget("project", "database", store)
    assert {:ok, [invalidated]} = Store.list("project", ["decision"], 10, store)

    assert {:error, :invalid_memory_list} = Store.list("project", "decision", 10, store)
    refute invalidated.active
    assert invalidated.kind == "decision"
  end
end
