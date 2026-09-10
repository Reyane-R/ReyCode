defmodule ReyCode.TUI.ActionTest do
  use ExUnit.Case, async: true

  defmodule Surface do
    use Breeze.View
    alias ReyCode.TUI.Action

    @impl true
    def mount(_opts, term), do: {:ok, term |> assign(count: 0, root_keys: []) |> focus("action")}

    @impl true
    def render(assigns) do
      ~H"""
      <box class="w-screen h-screen">
        <box id="action" implicit={Action} focusable br-change="activate">Activate</box>
        <box>Activations: {@count}</box>
      </box>
      """
    end

    @impl true
    def handle_event("activate", %{}, term),
      do: {:noreply, assign(term, count: term.assigns.count + 1)}

    def handle_event(:input, %{"key" => key}, term),
      do: {:noreply, assign(term, root_keys: [key | term.assigns.root_keys])}

    def handle_event(_, _, term), do: {:noreply, term}
  end

  test "Enter and Space activate once through br-change without also reaching the root key handler" do
    session = start_surface()

    for {key, count} <- [{"Enter", 1}, {" ", 2}] do
      Breeze.Test.input(session, key)
      assert Breeze.Test.render!(session) =~ "Activations: #{count}"
      assert Breeze.Test.metadata(session).assigns.root_keys == []
    end

    Breeze.Test.input(session, "x")
    assert Breeze.Test.metadata(session).assigns.root_keys == ["x"]
    assert Breeze.Test.metadata(session).assigns.count == 2
  end

  test "only left mouse press activates; release, right press and wheel are inert" do
    session = start_surface()

    for {button, action} <- [{"right", "press"}, {"left", "release"}, {"wheel_down", "press"}] do
      mouse(session, button, action)
      assert Breeze.Test.metadata(session).assigns.count == 0
    end

    mouse(session, "left", "press")
    assert Breeze.Test.metadata(session).assigns.count == 1
    mouse(session, "left", "release")
    assert Breeze.Test.metadata(session).assigns.count == 1
  end

  defp start_surface do
    session = Breeze.Test.start!(Surface, size: {60, 20})
    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render!(session)
    session
  end

  defp mouse(session, button, action),
    do:
      Breeze.Test.input(session, %{
        "mouse" => %{"button" => button, "action" => action, "x" => 2, "y" => 0}
      })
end
