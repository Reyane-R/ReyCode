defmodule ReyCode.Tool.MemoryTest do
  use ExUnit.Case, async: true

  alias ReyCode.Memory.Store
  alias ReyCode.Tool.{Memory, Request, Result}

  setup do
    path =
      Path.join(System.tmp_dir!(), "tool-memory-#{System.unique_integer([:positive])}.sqlite3")

    store = start_supervised!({Store, name: nil, path: path})
    on_exit(fn -> File.rm(path) end)
    %{store: store}
  end

  test "records structured decisions while legacy retain stays byte-compatible", %{store: store} do
    workspace = "memory-tool-#{System.unique_integer([:positive])}"

    legacy =
      Request.new(
        tool: "memory",
        arguments: %{"action" => "retain", "key" => "legacy", "value" => "plain"},
        workspace: workspace
      )

    assert %Result{ok: true, output: output} = Memory.run(legacy, server: store)
    assert Jason.decode!(output)["kind"] == "retain"
    assert {:ok, [legacy_memory]} = Store.list(workspace, [], 10, store)
    assert legacy_memory.value == "plain"
    assert legacy_memory.tags == []

    decision =
      Request.new(
        tool: "memory",
        arguments: %{
          "action" => "retain",
          "kind" => "decision",
          "key" => "database",
          "value" => "Use SQLite",
          "rationale" => "The EventStore is single-writer",
          "alternatives" => "PostgreSQL",
          "evidence" => "lib/rey_code/event_store/sqlite.ex",
          "tags" => ["storage"]
        },
        workspace: workspace
      )

    assert %Result{ok: true} = Memory.run(decision, server: store)
    assert {:ok, [stored]} = Store.list(workspace, ["decision"], 10, store)
    value = Jason.decode!(stored.value)
    assert value["statement"] == "Use SQLite"
    assert value["rationale"] == "The EventStore is single-writer"
    assert value["alternatives"] == "PostgreSQL"
    assert value["evidence"] == "lib/rey_code/event_store/sqlite.ex"
    assert stored.tags == ["decision", "storage"]

    learn =
      Request.new(
        tool: "memory",
        arguments: %{"action" => "learn", "key" => "lesson", "value" => "Prefer bounds"},
        workspace: workspace
      )

    assert %Result{ok: true} = Memory.run(learn, server: store)

    fact =
      Request.new(
        tool: "memory",
        arguments: %{
          "action" => "retain",
          "kind" => "fact",
          "key" => "runtime",
          "value" => "OTP 28"
        },
        workspace: workspace
      )

    assert %Result{ok: true} = Memory.run(fact, server: store)

    recall =
      Request.new(
        tool: "memory",
        arguments: %{"action" => "recall", "query" => "SQLite"},
        workspace: workspace
      )

    assert %Result{ok: true, output: recalled} = Memory.run(recall, server: store)
    assert [%{"key" => "database"}] = Jason.decode!(recalled)

    reflect =
      Request.new(tool: "memory", arguments: %{"action" => "reflect"}, workspace: workspace)

    assert %Result{ok: true, output: reflected} = Memory.run(reflect, server: store)
    assert Jason.decode!(reflected)["count"] == 4

    forget =
      Request.new(
        tool: "memory",
        arguments: %{"action" => "forget", "key" => "database"},
        workspace: workspace
      )

    assert %Result{ok: true, output: "forgot database"} = Memory.run(forget, server: store)
  end

  test "rejects unknown kinds and invalid structured fields", %{store: store} do
    workspace = "memory-tool-invalid-#{System.unique_integer([:positive])}"

    invalid_kind =
      Request.new(
        tool: "memory",
        arguments: %{
          "action" => "retain",
          "kind" => "guess",
          "key" => "bad",
          "value" => "bad"
        },
        workspace: workspace
      )

    assert %Result{ok: false, error: :invalid_memory_kind} =
             Memory.run(invalid_kind, server: store)

    invalid_value =
      Request.new(
        tool: "memory",
        arguments: %{
          "action" => "retain",
          "kind" => "assumption",
          "key" => "bad-rationale",
          "value" => "Assume Linux",
          "rationale" => 42
        },
        workspace: workspace
      )

    assert %Result{ok: false, error: :invalid_memory_value} =
             Memory.run(invalid_value, server: store)
  end
end
