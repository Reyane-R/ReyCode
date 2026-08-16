defmodule ReyCode.TUI.RenderComponentsTest do
  use ExUnit.Case, async: false

  test "imported components preserve named textarea events and focus" do
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

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "x")
    assert Breeze.Test.metadata(session).assigns.drafts["room-reycode"] == "x"

    assert {:noreply, "new-room-name", true} = Breeze.Test.input(session, ctrl("n"))
    Breeze.Test.render!(session)
    assert {:noreply, "new-room-name", true} = Breeze.Test.input(session, "R")
    assert Breeze.Test.metadata(session).assigns.new_room.name == "R"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
  end

  defp ctrl(key), do: %{"ctrlKey" => true, "key" => key}
end
