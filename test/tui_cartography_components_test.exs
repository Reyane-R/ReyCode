defmodule ReyCode.TUI.CartographyComponentsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Invocation, Message, Participant, Projection, Session, ToolRun}

  alias ReyCode.TUI.{
    ContextBoundary,
    Hotkeys,
    Notice,
    PromptHistory,
    SessionTree,
    ToolInspector
  }

  defmodule EngineStub do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    def handle_call({:fork_session, session_id, sequence}, _from, test_pid) do
      send(test_pid, {:forked, session_id, sequence})
      {:reply, {:ok, session_id}, test_pid}
    end
  end

  test "ContextBoundary opens, pages, closes, and directs empty state" do
    summary = Enum.map_join(1..40, "\n", &"summary line #{&1}")

    session = %Session{
      id: "session",
      context_boundary_sequence: 42,
      context_summary: summary,
      context_compacted_at: "now"
    }

    term = base_term(session)
    opened = ContextBoundary.open(term)
    assert opened.assigns.modal == :context_boundary
    assert ContextBoundary.focus(opened) == opened

    assert {:noreply, paged} = ContextBoundary.handle_input("PageDown", opened)
    assert paged.assigns.context_boundary.offset > 0
    assert {:noreply, previous} = ContextBoundary.handle_input("PageUp", paged)
    assert previous.assigns.context_boundary.offset == 0
    assert {:noreply, unchanged} = ContextBoundary.handle_input("unknown", previous)
    assert unchanged == previous
    assert ContextBoundary.handle_event("unknown", %{}, previous) == :unhandled
    assert {:noreply, closed} = ContextBoundary.submit(previous)
    assert closed.assigns.modal == nil

    empty = put_in(term.assigns.projection.sessions[session.id].context_boundary_sequence, 0)
    assert %Notice{severity: :info} = ContextBoundary.open(empty).assigns.notice
  end

  test "Hotkeys pages effective actions and closes from both controls" do
    entries =
      Enum.map(1..30, fn index ->
        %{id: "action.#{index}", label: "Action #{index}", chords: ["^#{index}"]}
      end)

    session = %Session{id: "session"}

    term =
      session
      |> base_term()
      |> put_in([Access.key(:assigns), :keybindings], %{
        entries: entries,
        errors: ["one warning"],
        path: "/tmp/keybindings.json"
      })

    opened = Hotkeys.open(term)
    assert opened.assigns.modal == :hotkeys
    assert Hotkeys.focus(opened) == opened
    assert {:noreply, moved} = Hotkeys.handle_input("j", opened)
    assert moved.assigns.hotkeys.offset == 1
    assert {:noreply, unmoved} = Hotkeys.handle_input("unknown", moved)
    assert unmoved == moved
    assert Hotkeys.handle_event("unknown", %{}, moved) == :unhandled
    assert {:noreply, closed} = Hotkeys.handle_input("Enter", moved)
    assert closed.assigns.modal == nil
  end

  test "PromptHistory searches, edits, moves, restores, and handles empty Sessions" do
    session = %Session{id: "session", message_order: ["first", "second"]}

    first = %Message{id: "first", role: :user, turn_id: "turn-1", body: "Fix the parser"}
    second = %Message{id: "second", role: :user, turn_id: "turn-2", body: "Run every test"}

    term =
      session
      |> base_term()
      |> put_in([Access.key(:assigns), :projection, Access.key(:messages)], %{
        first.id => first,
        second.id => second
      })

    opened = PromptHistory.open(term)
    assert opened.assigns.modal == :prompt_history
    assert PromptHistory.focus(opened) == opened
    assert {:noreply, moved} = PromptHistory.handle_input("ArrowDown", opened)
    assert moved.assigns.prompt_history.index == 1
    assert {:noreply, queried} = PromptHistory.handle_input("p", moved)
    assert queried.assigns.prompt_history.query == "p"
    assert {:noreply, erased} = PromptHistory.handle_input("Backspace", queried)
    assert erased.assigns.prompt_history.query == ""
    assert PromptHistory.handle_event("unknown", %{}, erased) == :unhandled
    assert {:noreply, restored} = PromptHistory.submit(erased)
    assert restored.assigns.drafts[session.id] == "Run every test"

    empty_session = %{session | message_order: []}
    empty = put_in(term.assigns.projection.sessions[session.id], empty_session)
    assert %Notice{severity: :info} = PromptHistory.open(empty).assigns.notice
  end

  test "ToolInspector navigates run list, pages detail, and handles empty state" do
    run = %ToolRun{
      id: "run-1",
      tool: "read",
      status: :completed,
      authorization: :auto,
      arguments: %{"path" => "lib/example.ex"},
      result: %{"output" => Enum.map_join(1..50, "\n", &"output #{&1}")}
    }

    invocation = %Invocation{
      id: "inv-1",
      session_id: "session",
      participant: %Participant{id: "assistant", name: "Assistant"},
      status: :completed,
      tool_runs: %{run.id => run},
      tool_run_order: [run.id]
    }

    message = %Message{id: "message", invocation_id: invocation.id}
    session = %Session{id: "session", message_order: [message.id]}

    projection = %Projection{
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{message.id => message},
      invocations: %{invocation.id => invocation}
    }

    term = %{base_term(session) | assigns: %{base_term(session).assigns | projection: projection}}
    opened = ToolInspector.open(term)
    assert opened.assigns.modal == :tool_inspector
    assert ToolInspector.focus(opened) == opened
    assert {:noreply, wrapped} = ToolInspector.handle_input("ArrowDown", opened)
    assert wrapped.assigns.tool_inspector.index == 0
    assert {:noreply, detail} = ToolInspector.submit(wrapped)
    assert detail.assigns.tool_inspector.step == :detail
    assert {:noreply, paged} = ToolInspector.handle_input("PageDown", detail)
    assert paged.assigns.tool_inspector.offset > 0
    assert {:noreply, list} = ToolInspector.handle_input("Escape", paged)
    assert list.assigns.tool_inspector.step == :list
    assert {:noreply, closed} = ToolInspector.handle_input("Escape", list)
    assert closed.assigns.modal == nil
    assert ToolInspector.handle_event("unknown", %{}, closed) == :unhandled

    empty = put_in(term.assigns.projection.invocations, %{})
    assert %Notice{severity: :info} = ToolInspector.open(empty).assigns.notice
  end

  test "SessionTree navigates, opens, forks, and handles an empty projection" do
    {:ok, engine} = EngineStub.start_link(self())
    root = %Session{id: "root", title: "Root", message_order: []}
    child = %Session{id: "child", title: "Child", parent_session_id: root.id, message_order: []}

    projection = %Projection{
      sequence: 12,
      sessions: %{root.id => root, child.id => child},
      session_order: [root.id, child.id]
    }

    term =
      root
      |> base_term()
      |> put_in([Access.key(:assigns), :engine], engine)
      |> put_in([Access.key(:assigns), :projection], projection)

    opened = SessionTree.open(term)
    assert opened.assigns.modal == :session_tree
    assert SessionTree.focus(opened) == opened
    assert {:noreply, moved} = SessionTree.handle_input("j", opened)
    assert moved.assigns.session_tree.index == 1
    assert {:noreply, forked} = SessionTree.handle_input("F", moved)
    assert %Notice{severity: :success} = forked.assigns.notice
    assert_receive {:forked, "child", 12}
    assert SessionTree.handle_event("unknown", %{}, moved) == :unhandled
    assert {:noreply, closed} = SessionTree.handle_input("Escape", moved)
    assert closed.assigns.modal == nil

    empty = put_in(term.assigns.projection, %Projection{})
    assert %Notice{severity: :info} = SessionTree.open(empty).assigns.notice
  end

  defp base_term(session) do
    %Breeze.Term{
      assigns: %{
        context_boundary: ContextBoundary.initial(),
        drafts: %{session.id => ""},
        hotkeys: Hotkeys.initial(),
        modal: nil,
        notice: nil,
        projection: %Projection{
          sessions: %{session.id => session},
          session_order: [session.id]
        },
        prompt_history: PromptHistory.initial(),
        selected_session_id: session.id,
        session_tree: SessionTree.initial(),
        slash: nil,
        tool_inspector: ToolInspector.initial()
      }
    }
  end
end
