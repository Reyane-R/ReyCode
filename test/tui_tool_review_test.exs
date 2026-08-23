defmodule ReyCode.TUI.ToolReviewTest do
  @moduledoc """
  Feature-owned coverage for the tool-approval modal exercised through the
  public TUI flow: open via `/tools`, render exact request details, cancel,
  and deny without side effects.
  """

  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:rey_code, :squad_simulator)

    Application.put_env(:rey_code, :squad_simulator,
      seed: 0,
      delay_ms: 0,
      tool_requests: [
        %{tool: "write", arguments: %{"path" => "out.txt", "content" => "approved-content"}}
      ]
    )

    snapshot = ReyCode.snapshot()

    room_id = Enum.find(snapshot.room_order, &(snapshot.rooms[&1].slug == "reycode"))
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Review this write", :compare)
    wait_until_waiting(turn_id)

    out_path = Path.join(File.cwd!(), "out.txt")

    on_exit(fn ->
      ReyCode.cancel_turn(turn_id)

      if previous do
        Application.put_env(:rey_code, :squad_simulator, previous)
      else
        Application.delete_env(:rey_code, :squad_simulator)
      end

      File.rm(out_path)
    end)

    %{room_id: room_id, turn_id: turn_id, out_path: out_path}
  end

  test "opens from the palette and renders the exact persisted request", %{
    turn_id: turn_id,
    out_path: out_path
  } do
    {session, _} = start_session(turn_id)

    type(session, "/tools")
    assert Breeze.Test.render!(session) =~ "Review a pending tool request"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = plain(Breeze.Test.render!(session))

    assert Breeze.Test.metadata(session).assigns.modal == :tool_review
    assert screen =~ "Tool approval"
    assert screen =~ "This request is waiting for owner approval."
    assert screen =~ "write"
    assert screen =~ "WRITE PATH"
    assert screen =~ "out.txt"
    assert screen =~ "CONTENT SIZE"
    assert screen =~ "16 bytes"
    assert screen =~ "CONTENT PREVIEW"
    assert screen =~ "approved-content"
    assert screen =~ "WORKSPACE"

    refute File.exists?(out_path)

    deny_selected(session)
    assert denied_invocation?(turn_id)
    refute File.exists?(out_path)
  end

  test "escape closes the review while the request stays pending", %{
    turn_id: turn_id,
    out_path: out_path
  } do
    {session, _} = start_session(turn_id)

    type(session, "/tools")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")

    refute Breeze.Test.render!(session) =~ "Tool approval"
    refute File.exists?(out_path)

    # The approval is still durable: reopening resumes the same review.
    type(session, "/tools")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :tool_review
    assert waiting?(turn_id)
  end

  defp deny_selected(session) do
    {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "d")
    wait_until_notice(session, "Tool request denied")
    refute Breeze.Test.render!(session) =~ "Tool approval"
  end

  defp denied_invocation?(turn_id) do
    snapshot = ReyCode.snapshot()

    Enum.any?(snapshot.turns[turn_id].invocation_order, fn id ->
      error = snapshot.invocations[id].error
      error != nil and error["category"] == "tool_denied"
    end)
  end

  defp wait_until_notice(session, text, attempts \\ 100)

  defp wait_until_notice(session, _text, 0) do
    flunk("notice never appeared; screen:\n#{plain(Breeze.Test.render!(session))}")
  end

  defp wait_until_notice(session, text, attempts) do
    if Breeze.Test.render!(session) =~ text do
      :ok
    else
      Process.sleep(25)
      wait_until_notice(session, text, attempts - 1)
    end
  end

  defp start_session(turn_id) do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 44},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    {session, turn_id}
  end

  defp type(session, text) do
    Breeze.Test.render!(session)

    for key <- String.graphemes(text) do
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, key)
      Breeze.Test.render!(session)
    end
  end

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  defp waiting?(turn_id) do
    snapshot = ReyCode.snapshot()

    Enum.any?(snapshot.turns[turn_id].invocation_order, fn id ->
      invocation = snapshot.invocations[id]
      invocation.status == :waiting_tool_approval or invocation.pending_tool_review != nil
    end)
  end

  defp wait_until_waiting(turn_id, attempts \\ 200)

  defp wait_until_waiting(_turn_id, 0), do: flunk("no invocation reached waiting_tool_approval")

  defp wait_until_waiting(turn_id, attempts) do
    if waiting?(turn_id) do
      :ok
    else
      Process.sleep(25)
      wait_until_waiting(turn_id, attempts - 1)
    end
  end
end
