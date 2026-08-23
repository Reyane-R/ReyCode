defmodule ReyCode.TUI.Render do
  @moduledoc "Breeze component composition for the terminal UI."

  use Breeze.Component

  import ReyCode.TUI.Components.MainScreen, only: [main_screen: 1]
  import ReyCode.TUI.Components.Modals, only: [active: 1]

  @doc "Renders the terminal UI from prepared view assigns."
  @spec render(map()) :: Breeze.Component.rendered()
  def render(assigns) do
    ~H"""
    <.main_screen
      modal={@modal}
      show_sidebar={@show_sidebar?}
      rooms={@rooms}
      selected_room_id={@selected_room_id}
      mode={@mode}
      room={@room}
      projection={@projection}
      providers={@providers}
      messages={@messages}
      timeline_id={@timeline_id}
      message_width={@message_width}
      draft={@draft}
      notice={@notice}
      slash={@slash}
      terminal_width={@breeze.terminal.width}
      terminal_height={@breeze.terminal.height}
    />
    <.active term={assigns}/>
    """
  end
end
