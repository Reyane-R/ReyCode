defmodule ReyCode.TUI.RenderComponentsTest do
  use ExUnit.Case, async: false

  test "composer events and new-session shortcut preserve prompt focus" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 32},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    Breeze.Test.render!(session)
    assert Breeze.Test.metadata(session).focused == "prompt"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.notice == "Write a message first"

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "x")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "x"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("n"))
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.home == true
    assert metadata.assigns.drafts[session_id] == ""
    assert Breeze.Test.render!(session) =~ "OPERATOR INSTRUMENT"
  end

  test "session header keeps the priority status on one line with a long workspace" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 32},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render!(session)

    engine = Breeze.Test.metadata(session).assigns.engine
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    projection = engine.snapshot()
    session_record = projection.sessions[session_id]

    turn_id = "turn-header-budget"
    invocation_id = "inv-header-budget"
    user_message_id = "msg-header-user"
    assistant_message_id = "msg-header-assistant"

    user_message = %{
      id: user_message_id,
      session_id: session_id,
      turn_id: nil,
      invocation_id: nil,
      author: %{kind: :user, id: "user", name: "You"},
      role: :user,
      status: :completed,
      body: "Inspect the header",
      created_at: "2026-08-24T20:00:00Z",
      created_sequence: projection.sequence,
      error: nil
    }

    assistant_message = %{
      id: assistant_message_id,
      session_id: session_id,
      turn_id: turn_id,
      invocation_id: invocation_id,
      author: %{kind: :agent, id: "assistant", name: "Assistant"},
      role: :assistant,
      status: :completed,
      body: "Done",
      created_at: "2026-08-24T20:00:01Z",
      created_sequence: projection.sequence,
      error: nil
    }

    long_workspace =
      "/opt/reycode-work/" <>
        Enum.map_join(1..10, "", &"directory-level-#{&1}/") <> "ReyCode"

    invocation = %{
      id: invocation_id,
      notes: [],
      participant: %{id: "assistant", name: "Assistant", provider: :simulator, model: "test"},
      session_id: session_id,
      turn_id: turn_id,
      status: :completed,
      attempt: 1,
      usage: %{"prompt_tokens" => 10, "completion_tokens" => 2},
      pending_tool_review: nil,
      delegated_from_invocation_id: nil,
      tool_runs: %{},
      tool_run_order: []
    }

    terminal_turn = %{
      mode: :direct,
      invocation_order: [invocation_id],
      status: :terminal,
      outcome: :completed,
      created_at: DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.to_iso8601()
    }

    projection =
      projection
      |> put_in([:sessions, session_id], %{
        session_record
        | active_turn_id: turn_id,
          workspace: long_workspace,
          message_order: [assistant_message_id, user_message_id]
      })
      |> put_in([:messages, user_message_id], user_message)
      |> put_in([:messages, assistant_message_id], assistant_message)
      |> put_in([:turns, turn_id], terminal_turn)
      |> put_in([:invocations, invocation_id], invocation)

    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = session |> Breeze.Test.render!() |> plain()

    assert screen =~ "✓ · Completed"
    assert screen =~ "EVT "
    assert screen =~ "TURN BUDGET TERMINAL"
    assert screen =~ "INV 01/01"
    assert screen =~ "GATE CLEAR"
    assert screen =~ "OUT COMPLETED"
    refute screen =~ long_workspace

    detached_dir =
      Path.join(System.tmp_dir!(), "rey-code-detached-\#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(detached_dir, ".git"))
    File.write!(Path.join(detached_dir, ".git/HEAD"), "0123456789abcdef0123456789abcdef\n")
    on_exit(fn -> File.rm_rf!(detached_dir) end)

    projection =
      put_in(projection, [:sessions, session_id, Access.key(:workspace)], detached_dir)

    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    assert session |> Breeze.Test.render!() |> plain() =~ "⑂ detached"

    checkout = File.cwd!()
    projection = put_in(projection, [:sessions, session_id, Access.key(:workspace)], checkout)
    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    assert session |> Breeze.Test.render!() |> plain() =~ "⑂ "

    long_ref_dir =
      Path.join(System.tmp_dir!(), "rey-code-longref-\#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(long_ref_dir, ".git"))

    File.write!(
      Path.join(long_ref_dir, ".git/HEAD"),
      "ref: refs/heads/feature/session-capability-pass\n"
    )

    on_exit(fn -> File.rm_rf!(long_ref_dir) end)

    projection = put_in(projection, [:sessions, session_id, Access.key(:workspace)], long_ref_dir)
    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    assert session |> Breeze.Test.render!() |> plain() =~ "⑂ feature/..."
  end

  defp ctrl(key), do: %{"ctrlKey" => true, "key" => key}

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  defp type(session, text) do
    Breeze.Test.render!(session)

    for key <- String.graphemes(text) do
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, key)
      Breeze.Test.render!(session)
    end
  end
end
