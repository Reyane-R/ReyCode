defmodule ReyCode.TUI.KeybindingsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Projection, Session}
  alias ReyCode.RuntimeConfig
  alias ReyCode.TUI.{Keybindings, SessionTree}

  test "bounded JSON overrides remap, disable, and report unknown actions" do
    path =
      Path.join(
        System.tmp_dir!(),
        "reycode-keybindings-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{
        "app.session.tree" => ["M-T", "^B"],
        "app.quit" => [],
        "unknown.action" => "^U"
      })
    )

    resolved = Keybindings.resolve(ReyCode.TUI.binding_actions(), path)
    by_id = Map.new(resolved.entries, &{&1.id, &1})

    assert by_id["app.session.tree"].chords == ["M-T", "^B"]
    assert by_id["app.quit"].chords == []
    assert resolved.errors == ["Unknown action unknown.action"]

    config = RuntimeConfig.fresh(tui_keybindings_path: path)
    chords = Enum.map(ReyCode.TUI.global_keybindings(config), &elem(&1, 0))
    assert "M-T" in chords
    refute "^Q" in chords
  end

  test "malformed keybinding files fail to built-in defaults with a visible error" do
    path =
      Path.join(
        System.tmp_dir!(),
        "reycode-keybindings-bad-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, "not json")

    resolved = Keybindings.resolve(ReyCode.TUI.binding_actions(), path)
    assert resolved.errors == ["Keybindings file is invalid JSON"]
    assert Enum.find(resolved.entries, &(&1.id == "app.quit")).chords == ["^Q"]
  end

  test "Session Tree orders roots and descendants in durable creation order" do
    root = %Session{id: "root", title: "Root", message_order: []}
    child = %Session{id: "child", title: "Child", parent_session_id: root.id, message_order: []}

    grandchild = %Session{
      id: "grandchild",
      title: "Grandchild",
      parent_session_id: child.id,
      message_order: []
    }

    orphan = %Session{
      id: "orphan",
      title: "Orphan",
      parent_session_id: "missing",
      message_order: []
    }

    projection = %Projection{
      sessions: Map.new([root, child, grandchild, orphan], &{&1.id, &1}),
      session_order: [root.id, child.id, grandchild.id, orphan.id]
    }

    assert Enum.map(SessionTree.rows(projection), &{&1.session.id, &1.depth}) == [
             {"root", 0},
             {"child", 1},
             {"grandchild", 2},
             {"orphan", 0}
           ]
  end

  test "feature shortcuts leave an existing modal in control" do
    term = %Breeze.Term{assigns: %{modal: :help}}

    assert {:noreply, ^term} = ReyCode.TUI.open_session_tree(nil, term)
    assert {:noreply, ^term} = ReyCode.TUI.open_tool_inspector(nil, term)
    assert {:noreply, ^term} = ReyCode.TUI.open_prompt_history(nil, term)
    assert {:noreply, ^term} = ReyCode.TUI.retry_latest(nil, term)
  end
end
