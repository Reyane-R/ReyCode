defmodule ReyCode.SessionExportTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Author,
    Invocation,
    Message,
    Participant,
    Projection,
    Session,
    ToolRun
  }

  alias ReyCode.SessionExport

  test "renders deterministic Markdown and escaped HTML without changing Projection" do
    session = %Session{
      id: "session-1",
      title: "Review <main>",
      workspace: "/workspace",
      message_order: ["assistant", "user"],
      parent_session_id: "session-parent",
      forked_from_sequence: 12
    }

    projection = %Projection{
      sequence: 20,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{
        "user" => %Message{
          id: "user",
          author: Author.user("You"),
          role: :user,
          status: :completed,
          body: "Ship it",
          created_sequence: 2
        },
        "assistant" => %Message{
          id: "assistant",
          author: %Author{kind: :agent, id: "assistant", name: "Assistant"},
          role: :assistant,
          status: :completed,
          body: "Done <safely>",
          created_sequence: 3
        }
      }
    }

    assert {:ok, markdown} = SessionExport.render(projection, session.id, :markdown)
    assert markdown =~ "# Review <main>"
    assert markdown =~ "Forked from `session-parent` at sequence 12"
    assert markdown =~ ~r/## You.*Ship it.*## Assistant.*Done <safely>/s

    assert {:ok, html} = SessionExport.render(projection, session.id, :html)
    assert html =~ "Review &lt;main&gt;"
    assert html =~ "Done &lt;safely&gt;"
    assert projection.sequence == 20
  end

  test "exports bounded decisions and ToolRun arguments from explicit trace inputs" do
    session = %Session{
      id: "session-trace",
      title: "Trace",
      workspace: "/workspace",
      message_order: ["assistant"]
    }

    message = %Message{
      id: "assistant",
      invocation_id: "invocation",
      author: %Author{kind: :agent, id: "assistant", name: "Assistant"},
      role: :assistant,
      status: :completed,
      body: "Implemented",
      created_sequence: 2
    }

    run = %ToolRun{
      id: "run",
      tool: "edit",
      status: :completed,
      arguments: %{"path" => "lib/example.ex", "replacement" => String.duplicate("x", 500)}
    }

    invocation = %Invocation{
      id: "invocation",
      participant: %Participant{id: "assistant", name: "Assistant"},
      status: :completed,
      tool_runs: %{run.id => run},
      tool_run_order: [run.id]
    }

    projection = %Projection{
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{message.id => message},
      invocations: %{invocation.id => invocation}
    }

    decisions = [
      %{
        id: "memory-1",
        project: session.workspace,
        kind: "decision",
        key: "storage",
        value:
          Jason.encode!(%{
            "statement" => "Use SQLite",
            "rationale" => "single writer",
            "evidence" => "event_store/sqlite.ex"
          }),
        tags: ["decision"],
        created_at: "2026-08-28T00:00:00Z",
        active: true
      }
    ]

    assert {:ok, markdown} = SessionExport.render(projection, session.id, :markdown, decisions)
    assert markdown =~ "## Decisions & assumptions"
    assert markdown =~ "Use SQLite · because single writer · evidence event_store/sqlite.ex"
    assert markdown =~ "args `"
    refute markdown =~ String.duplicate("x", 500)

    assert {:ok, html} = SessionExport.render(projection, session.id, :html, decisions)
    assert html =~ "Decisions &amp; assumptions"
    assert html =~ "args"
  end
end
