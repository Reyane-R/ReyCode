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
      home={@home}
      recent_session_rows={@recent_session_rows}
      mode={@mode}
      room={@room}
      projection={@projection}
      providers={@providers}
      messages={@messages}
      timeline_id={@timeline_id}
      message_width={@message_width}
      slash_rows={@slash_rows}
      slash_style={@slash_style}
      git_branch={@git_branch}
      token_label={@token_label}
      elapsed_seconds={@elapsed_seconds}
      terminal_width={@breeze.terminal.width}
      terminal_height={@breeze.terminal.height}
      draft={@draft}
      notice={@notice}
      slash={@slash}
    />
    <.active term={assigns}/>
    """
  end
end
