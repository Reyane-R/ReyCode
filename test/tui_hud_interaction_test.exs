defmodule ReyCode.TUI.HUDInteractionTest do
  use ExUnit.Case, async: true

  defmodule ScrollFooterView do
    use Breeze.View
    import Breeze.Blocks
    alias ReyCode.TUI.Action

    @impl true
    def mount(_opts, term), do: {:ok, assign(term, accepted: false)}

    @impl true
    def render(assigns) do
      ~H"""
      <box class="w-screen h-screen grid grid-cols-1 grid-rows-2">
        <.scroll id="history" class="w-full h-full overflow-scroll" scroll-autoscroll="bottom">
          <box :for={index <- 1..20} id={"row-#{index}"}>History {index}</box>
        </.scroll>
        <box id="accept" implicit={Action} br-change="accept" class="w-full h-2">Accept</box>
      </box>
      """
    end

    @impl true
    def handle_event("accept", _payload, term), do: {:noreply, assign(term, accepted: true)}
    def handle_event(_event, _payload, term), do: {:noreply, term}
  end

  test "clipped history rows cannot intercept the footer at the scroll boundary" do
    session = Breeze.Test.start!(ScrollFooterView, size: {40, 8})
    on_exit(fn -> Breeze.Test.stop(session) end)
    assert Breeze.Test.render!(session) =~ "Accept"

    Breeze.Test.input(session, %{
      "mouse" => %{"button" => "left", "action" => "press", "x" => 3, "y" => 6}
    })

    assert Breeze.Test.metadata(session).assigns.accepted
  end
end
