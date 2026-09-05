defmodule ReyCode.TUI.CommandActionsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{Projection, Session}
  alias ReyCode.TUI.{AnimationClock, Notice, SessionCommand, WorkCommand}

  defmodule EngineStub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:fork_session, _room_id, _sequence}, _from, state),
      do: {:reply, {:ok, "session-fork"}, state}

    def handle_call({:steer_turn, _turn_id, _body}, _from, state),
      do: {:reply, :ok, state}

    def handle_call({:dequeue_latest_follow_up, _room_id}, _from, state),
      do: {:reply, {:ok, "Recovered follow-up"}, state}
  end

  test "Session commands fork, validate rewind, and export" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "rey-code-session-command-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    engine = start_supervised!({EngineStub, []})
    term = term(engine, workspace)

    assert {:noreply, forked} = SessionCommand.run(term, "/fork", nil)
    assert forked.assigns.selected_session_id == "session-fork"

    assert {:noreply, invalid} = SessionCommand.run(term, "/rewind", "invalid")
    assert %Notice{severity: :warning} = invalid.assigns.notice

    assert {:noreply, exported} = SessionCommand.run(term, "/export", nil)
    assert %Notice{severity: :success} = exported.assigns.notice
    assert File.exists?(Path.join([workspace, ".reycode", "exports", "room-1.md"]))
  end

  test "work commands steer active work and return the newest FollowUp to the composer" do
    workspace = System.tmp_dir!()
    engine = start_supervised!({EngineStub, []})
    term = term(engine, workspace, "turn-1")

    assert {:noreply, steered} = WorkCommand.run(term, "/steer", "use less code")
    assert %Notice{severity: :success} = steered.assigns.notice

    assert {:noreply, dequeued} = WorkCommand.run(term, "/dequeue", nil)
    assert %Notice{severity: :success} = dequeued.assigns.notice
    assert dequeued.assigns.drafts["room-1"] == "Recovered follow-up"
  end

  defp term(engine, workspace, active_turn_id \\ nil) do
    session = %Session{
      id: "room-1",
      title: "Session",
      workspace: workspace,
      active_turn_id: active_turn_id
    }

    %Breeze.Term{
      assigns: %{
        drafts: %{session.id => ""},
        engine: engine,
        projection: %Projection{
          sequence: 12,
          sessions: %{session.id => session},
          session_order: [session.id]
        },
        selected_session_id: session.id,
        modal: :slash,
        slash: nil,
        notice: nil,
        animation_clock:
          AnimationClock.new(
            schedule: fn _token, _delay -> make_ref() end,
            cancel: fn _timer -> :ok end
          ),
        animation_now_ms: 0,
        providers: %{}
      }
    }
  end
end
