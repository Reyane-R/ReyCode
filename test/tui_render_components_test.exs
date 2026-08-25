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

    session_id = Breeze.Test.metadata(session).assigns.selected_room_id
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "x")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "x"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("n"))
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.home == true
    assert metadata.assigns.drafts[session_id] == ""
    assert Breeze.Test.render!(session) =~ "Welcome to ReyCode"
  end

  defp ctrl(key), do: %{"ctrlKey" => true, "key" => key}
end
