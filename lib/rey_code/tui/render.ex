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
      session={@session}
      projection={@projection}
      providers={@providers}
      messages={@messages}
      activity={@activity}
      activity_frame={@activity_frame}
      timeline_id={@timeline_id}
      message_width={@message_width}
      slash_rows={@slash_rows}
      slash_style={@slash_style}
      git_branch={@git_branch}
      question_label={@question_label}
      update_notice={@update_notice}
      token_label_class={@token_label_class}
      token_label={@token_label}
      terminal_width={@breeze.terminal.width}
      terminal_height={@breeze.terminal.height}
      draft={@draft}
      notice={@notice}
      budget_notice={@budget_notice}
      composer_status={@composer_status}
      slash={@slash}
    />
    <.active term={assigns}/>
    """
  end
end
