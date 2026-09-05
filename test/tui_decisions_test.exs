defmodule ReyCode.TUI.DecisionsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Memory.Store
  alias ReyCode.Orchestration.{Projection, Session}
  alias ReyCode.TUI.{Decisions, Notice}

  test "browses structured rationale and invalidates without deleting history" do
    workspace = "decisions-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{workspace}.sqlite3")
    store = start_supervised!({Store, name: nil, path: path})
    on_exit(fn -> File.rm(path) end)

    value =
      Jason.encode!(%{
        "statement" => "Use SQLite",
        "rationale" => "The EventStore is single-writer",
        "alternatives" => "PostgreSQL",
        "evidence" => "lib/rey_code/event_store/sqlite.ex"
      })

    assert {:ok, _memory} =
             Store.record(workspace, "decision", "database", value, ["decision"], store)

    term = term(workspace, store)
    opened = Decisions.open(term)
    assert opened.assigns.modal == :decisions
    assert Decisions.focus(opened) == opened
    assert {:noreply, detail} = Decisions.submit(opened)
    assert detail.assigns.decisions.step == :detail
    assert {:noreply, invalidated} = Decisions.handle_input("Y", detail)
    assert %Notice{severity: :success} = invalidated.assigns.notice
    assert {:ok, [entry]} = Store.list(workspace, ["decision"], 10, store)
    refute entry.active
    assert entry.value == value

    assert {:noreply, list} = Decisions.handle_input("Escape", invalidated)
    assert list.assigns.decisions.step == :list
    assert {:noreply, closed} = Decisions.handle_input("Escape", list)
    assert closed.assigns.modal == nil
    assert Decisions.handle_event("unknown", %{}, closed) == :unhandled
  end

  test "opens a truthful empty state and ignores selection controls" do
    workspace = "decisions-empty-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{workspace}.sqlite3")
    store = start_supervised!({Store, name: nil, path: path})
    on_exit(fn -> File.rm(path) end)

    opened = Decisions.open(term(workspace, store))
    assert opened.assigns.modal == :decisions
    assert {:noreply, ^opened} = Decisions.handle_input("j", opened)
    assert {:noreply, ^opened} = Decisions.submit(opened)
  end

  defp term(workspace, store) do
    session = %Session{id: "session", workspace: workspace}

    %Breeze.Term{
      assigns: %{
        decisions: Decisions.initial(),
        drafts: %{session.id => ""},
        memory_store: store,
        modal: nil,
        notice: nil,
        projection: %Projection{
          sessions: %{session.id => session},
          session_order: [session.id]
        },
        selected_session_id: session.id,
        slash: nil
      }
    }
  end
end
