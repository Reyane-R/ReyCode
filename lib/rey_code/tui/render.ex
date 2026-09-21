defmodule ReyCode.TUI.Render do
  @moduledoc "Breeze component composition for the terminal UI."

  use Breeze.Component

  import ReyCode.TUI.Components.MainScreen, only: [main_screen: 1]
  import ReyCode.TUI.Components.Modals, only: [active: 1]
  import ReyCode.TUI.Components.HUD, only: [modal_chrome: 1]

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
      selected_session_id={@selected_session_id}
      projection={@projection}
      operator_question={@operator_question}
      providers={@providers}
      messages={@messages}
      activity={@activity}
      wall={@blackwall}
      activity_frame={@activity_frame}
      motion={not @config.tui.reduced_motion?}
      ascii={@animation_style == :ascii}
      rail_width={@rail_width}
      content_width={@content_width}
      timeline_id={@timeline_id}
      message_width={@message_width}
      slash_rows={@slash_rows}
      slash_style={@slash_style}
      git_branch={@git_branch}
      question_label={@question_label}
      update_notice={@update_notice}
      token_label_class={@token_label_class}
      token_label={@token_label}
      text_selection={@text_selection}
      terminal_width={@breeze.terminal.width}
      terminal_height={@breeze.terminal.height}
      draft={@draft}
      notice={@notice}
      composer_status={@composer_status}
      slash={@slash}
    />
    <box :if={@modal not in [nil, :slash, :operator_question]} class="w-screen h-screen bg">
      <.active term={assigns}/>
      <.modal_chrome term={assigns}/>
    </box>
    """
  end
end
