defmodule ReyCode.TUI.RecoveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Message, Projection, Session, Turn}
  alias ReyCode.TUI.{Notice, Recovery}

  defmodule EngineStub do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    def handle_call({:retry_turn, turn_id}, _from, test_pid) do
      send(test_pid, {:retried, turn_id})
      {:reply, {:ok, "turn-retry"}, test_pid}
    end

    def handle_call({:dequeue_latest_follow_up, session_id}, _from, test_pid) do
      send(test_pid, {:dequeued, session_id})
      {:reply, {:ok, "Recovered follow-up"}, test_pid}
    end
  end

  test "retry and dequeue actions retain durable ownership and restore the composer" do
    {:ok, engine} = EngineStub.start_link(self())

    session = %Session{id: "session", message_order: ["message"], queued_turn_ids: ["queued"]}

    message = %Message{
      id: "message",
      session_id: session.id,
      turn_id: "failed",
      role: :user,
      body: "Try again"
    }

    failed = %Turn{id: "failed", session_id: session.id, status: :terminal, outcome: :failed}

    projection = %Projection{
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{message.id => message},
      turns: %{failed.id => failed}
    }

    term = %Breeze.Term{
      assigns: %{
        drafts: %{session.id => ""},
        engine: engine,
        modal: :slash,
        notice: nil,
        projection: projection,
        selected_session_id: session.id,
        slash: nil
      }
    }

    retry_term = put_in(term.assigns.modal, nil)
    assert {:noreply, retried} = ReyCode.TUI.retry_latest(nil, retry_term)
    assert %Notice{severity: :success} = retried.assigns.notice
    assert_receive {:retried, "failed"}

    assert {:noreply, dequeued} = Recovery.dequeue_latest(term)
    assert %Notice{severity: :success} = dequeued.assigns.notice
    assert dequeued.assigns.drafts[session.id] == "Recovered follow-up"
    assert_receive {:dequeued, "session"}
  end

  test "retry reports when the Session has no failed Turn" do
    {:ok, engine} = EngineStub.start_link(self())
    session = %Session{id: "empty", message_order: []}

    term = %Breeze.Term{
      assigns: %{
        drafts: %{session.id => ""},
        engine: engine,
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

    assert {:noreply, unchanged} = Recovery.retry_latest(term)
    assert %Notice{severity: :info} = unchanged.assigns.notice
  end
end
