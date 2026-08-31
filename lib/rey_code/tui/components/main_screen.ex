defmodule ReyCode.TUI.Components.MainScreen do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  import ReyCode.TUI.Components.MainScreen.Timeline, only: [timeline: 1]

  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.Activity
  attr :modal, :any, required: true
  attr :home, :boolean, required: true
  attr :sessions, :list, required: true
  attr :mode, :atom, required: true
  attr :session, :map, required: true
  attr :projection, :map, required: true
  attr :providers, :map, required: true
  attr :messages, :list, required: true
  attr :activity, :map, required: true
  attr :activity_frame, :string, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :draft, :string, required: true
  attr :notice, :any, required: true
  attr :budget_notice, :any, required: true
  attr :token_label_class, :string, required: true
  attr :update_notice, :string, required: true
  attr :event_rail, :map, required: true

  attr :terminal_width, :integer, required: true
  attr :terminal_height, :integer, required: true

  def main_screen(assigns) do
    ~H"""
    <box :if={@modal in [nil, :slash]} class="w-screen h-screen bg">
      <box class={content_class(@home)}>
        <.home_panel
          :if={@home}
          session={@session}
          recent_session_rows={@recent_session_rows}
          update_notice={@update_notice}
        />
        <.session_header
          :if={session_visible?(@home)}
          session={@session}
          activity={@activity}
          activity_frame={@activity_frame}
          git_branch={@git_branch}
          question_label={@question_label}
          update_notice={@update_notice}
          token_label={@token_label}
          token_label_class={@token_label_class}
          event_rail={@event_rail}
          terminal_width={@terminal_width}
        />
        <.timeline
          :if={session_visible?(@home)}
          messages={@messages}
          timeline_id={@timeline_id}
          message_width={@message_width}
          activity_frame={@activity_frame}
        />
        <.composer draft={@draft} notice={@notice} budget_notice={@budget_notice}/>
        <.slash_palette
          modal={@modal}
          slash_rows={@slash_rows}
          slash_style={@slash_style}
          slash_empty_label={@slash_empty_label}
        />
      </box>
    </box>
    """
  end

  attr :session, :map, required: true
  attr :recent_session_rows, :list, required: true
  attr :update_notice, :string, required: true

  defp home_panel(assigns) do
    ~H"""
    <box class="h-full w-full px-4 pt-2 overflow-hidden">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">REYCODE</box>
        <box class="pl-2 text-muted">/ OPERATOR INSTRUMENT</box>
        <box :if={@update_notice} class="w-full text-right text-warning">{@update_notice}</box>
      </box>
      <box class="pt-2 text-muted">SYSTEM / PRIMARY PARTICIPANT</box>
      <box class="font-bold">{primary_summary(@session)}</box>
      <box class="pt-2 text-muted">CONTROL INDEX</box>
      <box class="inline w-full">
        <box class="w-12 text-muted">CMD /</box>
        <box>/  command palette</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">AGENT /</box>
        <box>/agent  create a task Participant</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">REVIEW /</box>
        <box>/advise  request an Advisor review</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">HUB /</box>
        <box>/hub  inspect child Invocations</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">FILE /</box>
        <box>@file  attach Workspace context</box>
      </box>
      <box class="pt-2 text-muted">TASK PARTICIPANTS / {length(task_participants(@session))}</box>
      <box :if={task_participants(@session) == []} class="text-muted">
        STANDBY / Create one when a repeatable responsibility is worth keeping.
      </box>
      <box :for={participant <- task_participants(@session)}>
        {participant.name}  /  {Presentation.short_runtime_label(participant)}
      </box>
      <box class="pt-2 text-muted">RECENT SESSIONS / {length(@recent_session_rows)}</box>
      <box :if={@recent_session_rows == []} class="text-muted">STANDBY / No prior activity</box>
      <box :for={session <- @recent_session_rows} class="text-muted">
        {session.title}  /  {session.meta}
      </box>
    </box>
    """
  end

  attr :session, :map, required: true
  attr :activity, :map, required: true
  attr :activity_frame, :string, required: true
  attr :git_branch, :any, required: true
  attr :question_label, :string, required: true
  attr :event_rail, :map, required: true
  attr :update_notice, :string, required: true
  attr :token_label_class, :string, required: true
  attr :terminal_width, :integer, required: true

  defp session_header(assigns) do
    ~H"""
    <box class="h-5 w-full bg-surface border-b border-muted px-2">
      <box class="inline w-full overflow-hidden">
        <box class="font-bold text-primary">REYCODE</box>
        <box class="text-muted">
          {header_context(@session, @terminal_width, @git_branch, @token_label)}
        </box>
        <box class={header_token_class(@token_label_class)}>{@token_label}</box>
        <box :if={@update_notice} class="pl-2 text-warning">{@update_notice}</box>
      </box>
      <.event_rail
        rail={@event_rail}
        activity={@activity.header}
        activity_frame={@activity_frame}
        question_label={@question_label}
        terminal_width={@terminal_width}
      />
    </box>
    """
  end

  attr :draft, :string, required: true
  attr :notice, :any, required: true
  attr :budget_notice, :any, required: true

  defp composer(assigns) do
    ~H"""
    <box class="h-7 w-full bg-surface border-t border-muted px-2 overflow-hidden">
      <box class="inline w-full">
        <box class="text-muted">INPUT / OPERATOR</box>
        <box :if={is_nil(@notice) and is_nil(@budget_notice)} class="w-full text-right text-muted">
          READY
        </box>
        <box :if={not is_nil(@notice)} class="w-full text-right text-error">ATTENTION</box>
        <box :if={not is_nil(@budget_notice)} class="w-full text-right text-warning">LIMIT</box>
      </box>
      <.textarea
        id="prompt"
        textarea-value={@draft}
        textarea-placeholder="Message the Assistant  /  commands  @  files"
        textarea-submit-on-enter={true}
        br-change="prompt_changed"
        br-submit="prompt_submitted"
        class={composer_input_class(@notice, @budget_notice)}
      />
      <box :if={is_nil(@notice) and is_nil(@budget_notice)} class="text-muted">
        ENTER SEND  /  SHIFT+ENTER LINE  /  ↑↓ HISTORY
      </box>
      <box :if={not is_nil(@notice)} class="text-error">FAULT / {@notice}</box>
      <box :if={not is_nil(@budget_notice)} class="text-warning">LIMIT / {@budget_notice}</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :slash_rows, :list, required: true
  attr :slash_style, :map, required: true

  attr :slash_empty_label, :string, required: true

  defp slash_palette(assigns) do
    ~H"""
    <box
      :if={@modal == :slash}
      class="bg-panel border-l border-r border-t border-muted overflow-hidden layer-40"
      style={@slash_style}
    >
      <box :for={row <- @slash_rows} class={row.option_class}>
        <box class={row.command_class}>{row.command}</box>
        <box class={row.description_class}>{row.description}</box>
      </box>
      <box
        :if={@slash_rows == [] and @slash_empty_label == "No matching commands"}
        class="w-full px-1 text-muted"
      >
        No matching commands
      </box>
      <box :if={@slash_rows == [] and @slash_empty_label == "No matching files"}>
        No matching files
      </box>
    </box>
    """
  end

  attr :rail, :map, required: true
  attr :activity, :any, required: true
  attr :activity_frame, :string, required: true
  attr :question_label, :string, required: true
  attr :terminal_width, :integer, required: true

  defp event_rail(assigns) do
    ~H"""
    <box class="inline w-full overflow-hidden">
      <box class="font-bold text-muted">EVT {@rail.sequence}</box>
      <box class="text-muted">  │  TURN {@rail.turn_id} </box>
      <box class={@rail.turn_class}>{@rail.turn}</box>
      <box class="text-muted">  │  INV </box>
      <box class={@rail.invocation_class}>{@rail.invocations}</box>
      <box class="text-muted">  │  GATE </box>
      <box class={@rail.gate_class}>{@rail.gate}</box>
      <box :if={@terminal_width >= 104} class="text-muted">  │  OUT </box>
      <box :if={@terminal_width >= 104} class={@rail.outcome_class}>{@rail.outcome}</box>
      <box :if={@terminal_width >= 120 and @question_label != ""} class="pl-2 text-warning">
        {@question_label}
      </box>
      <box :if={@terminal_width >= 96} class={event_activity_class(@activity)}>
        {Activity.header_text(@activity, @activity_frame)}
      </box>
    </box>
    """
  end

  defp composer_input_class(nil, nil),
    do: "w-full h-3 border focus:border-primary bg-surface"

  defp composer_input_class(_notice, _budget_notice),
    do: "w-full h-2 border focus:border-primary bg-surface"

  defp primary_summary(session) do
    case Enum.find(session.participants, &(&1.kind == :primary)) do
      nil -> "Assistant setup required"
      participant -> "#{participant.name}  ·  #{Presentation.short_runtime_label(participant)}"
    end
  end

  defp task_participants(session), do: Enum.filter(session.participants, &(&1.kind == :task))

  defp primary_runtime(session) do
    case Enum.find(session.participants, &(&1.kind == :primary)) do
      nil -> "model required"
      participant -> Presentation.short_runtime_label(participant)
    end
  end

  defp header_context(session, terminal_width, git_branch, token_label) do
    runtime = primary_runtime(session)
    branch = if is_binary(git_branch), do: " / " <> git_branch, else: ""

    # The header is one terminal line, and Breeze inline boxes abut without
    # gutters. Reserve every other segment's exact length plus a safety
    # margin; the workspace absorbs the remainder.
    reserved =
      String.length("REYCODE") + String.length(runtime) + String.length(branch) +
        String.length(" / ") + String.length(token_label) + 8

    " / " <>
      runtime <>
      branch <>
      " / " <>
      workspace_context(session.workspace, max(terminal_width - reserved, 12))
  end

  defp header_token_class(class), do: "w-full text-right " <> class
  defp event_activity_class(item), do: "w-full text-right text-#{Activity.color(item)}"

  defp workspace_context(path, max_length) do
    path
    |> compact_home()
    |> middle_truncate(max(max_length, 12))
  end

  defp compact_home(path) do
    home = System.user_home!()

    cond do
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~/" <> Path.relative_to(path, home)
      true -> path
    end
  end

  defp middle_truncate(value, max_length) do
    if String.length(value) <= max_length do
      value
    else
      left_length = div(max_length - 3, 2)
      right_length = max_length - 3 - left_length

      String.slice(value, 0, left_length) <>
        "..." <> String.slice(value, -right_length, right_length)
    end
  end

  defp session_visible?(true), do: false
  defp session_visible?(_home), do: true

  defp content_class(true), do: "grid grid-cols-1 grid-rows-2 h-full w-full overflow-hidden"
  defp content_class(_home), do: "grid grid-cols-1 grid-rows-3 h-full w-full overflow-hidden"
end
