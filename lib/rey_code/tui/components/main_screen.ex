defmodule ReyCode.TUI.Components.MainScreen do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  import ReyCode.TUI.Components.MainScreen.Timeline, only: [timeline: 1]

  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.Activity
  alias ReyCode.TUI.Notice
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
  attr :composer_status, :map, required: true
  attr :token_label_class, :string, required: true
  attr :update_notice, :any, required: true

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
          composer_status={@composer_status}
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
          terminal_width={@terminal_width}
        />
        <.timeline
          :if={session_visible?(@home)}
          messages={@messages}
          timeline_id={@timeline_id}
          message_width={@message_width}
          activity_frame={@activity_frame}
        />
        <.composer
          draft={@draft}
          notice={@notice}
          budget_notice={@budget_notice}
          composer_status={@composer_status}
        />
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
  attr :composer_status, :map, required: true
  attr :update_notice, :any, required: true

  defp home_panel(assigns) do
    ~H"""
    <.scroll id="home-scroll" class="h-full w-full overflow-scroll mute-scrollbar-40 px-4 pt-2">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">REYCODE</box>
        <box class="pl-2 text-muted">AI workbench</box>
        <box :if={@update_notice} class={"w-full text-right " <> Notice.text_class(@update_notice)}>
          {@update_notice.message}
        </box>
      </box>
      <box class="pt-2 text-muted">Workspace</box>
      <box class="font-bold">{compact_home(@session.workspace)}</box>
      <box class="pt-2 text-muted">Assistant</box>
      <box class="inline w-full">
        <box class="font-bold">{primary_summary(@session)}</box>
        <box
          :if={@composer_status.label != "Ready"}
          class={"w-full text-right " <> @composer_status.class}
        >
          {@composer_status.label}
        </box>
      </box>
      <box class="pt-2 text-muted">Quick start</box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/</box>
        <box>Browse commands</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">@file</box>
        <box>Attach workspace context</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/resume</box>
        <box>Continue a previous session</box>
      </box>
      <box class="pt-2 text-muted">More</box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/connect</box>
        <box>Choose a model provider</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/agent</box>
        <box>Create a teammate</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/advise</box>
        <box>Request a second opinion</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/hub</box>
        <box>Inspect delegated work</box>
      </box>
      <box class="pt-2 text-muted">Teammates · {length(task_participants(@session))}</box>
      <box :if={task_participants(@session) == []} class="text-muted">
        None yet. Create one when a responsibility repeats.
      </box>
      <box :for={participant <- task_participants(@session)}>
        {participant.name} · {Presentation.short_runtime_label(participant)}
      </box>
      <box class="pt-2 text-muted">Recent sessions · {length(@recent_session_rows)}</box>
      <box :if={@recent_session_rows == []} class="text-muted">No previous sessions.</box>
      <box :for={session <- @recent_session_rows} class="text-muted">
        {session.title} · {session.meta}
      </box>
    </.scroll>
    """
  end

  attr :session, :map, required: true
  attr :activity, :map, required: true
  attr :activity_frame, :string, required: true
  attr :git_branch, :any, required: true
  attr :question_label, :string, required: true
  attr :update_notice, :any, required: true
  attr :token_label_class, :string, required: true
  attr :terminal_width, :integer, required: true

  defp session_header(assigns) do
    ~H"""
    <box class="h-5 w-full bg-surface border-b border-muted px-2">
      <box class="inline w-full overflow-hidden">
        <box class="font-bold text-primary">{primary_summary(@session)}</box>
        <box class="text-muted">
          {header_context(@session, @terminal_width, @git_branch, @token_label)}
        </box>
        <box class={header_token_class(@token_label_class)}>{@token_label}</box>
      </box>
      <box class="inline w-full overflow-hidden">
        <box class={work_pulse_class(@activity.header)}>
          {Activity.header_text(@activity.header, @activity_frame)}
        </box>
        <box :if={@question_label != ""} class="w-full text-right text-warning">
          {@question_label}
        </box>
        <box
          :if={@question_label == "" and @update_notice}
          class={"w-full text-right " <> Notice.text_class(@update_notice)}
        >
          {@update_notice.message}
        </box>
      </box>
    </box>
    """
  end

  attr :draft, :string, required: true
  attr :notice, :any, required: true
  attr :budget_notice, :any, required: true
  attr :composer_status, :map, required: true

  defp composer(assigns) do
    ~H"""
    <box class="h-6 w-full bg-surface border-t border-muted px-2 overflow-hidden">
      <box class="inline w-full">
        <box class="font-bold text-primary">Message Assistant</box>
        <box
          :if={is_nil(@notice) and is_nil(@budget_notice)}
          class={"w-full text-right " <> @composer_status.class}
        >
          {@composer_status.label}
        </box>
        <box :if={not is_nil(@notice)} class={"w-full text-right " <> Notice.text_class(@notice)}>
          {Notice.label(@notice)}
        </box>
        <box
          :if={is_nil(@notice) and not is_nil(@budget_notice)}
          class="w-full text-right text-warning"
        >
          {Notice.label(@budget_notice)}
        </box>
      </box>
      <.textarea
        id="prompt"
        textarea-value={@draft}
        textarea-placeholder="Ask anything…  / commands  @ files"
        textarea-submit-on-enter={true}
        br-change="prompt_changed"
        br-submit="prompt_submitted"
        class="w-full h-2 border focus:border-primary bg-surface"
      />
      <box :if={is_nil(@notice) and is_nil(@budget_notice)} class="text-muted">
        Enter send · Shift+Enter new line · ↑↓ history
      </box>
      <box :if={not is_nil(@notice)} class={Notice.text_class(@notice)}>
        {Notice.label(@notice)} · {@notice.message}
      </box>
      <box
        :if={is_nil(@notice) and not is_nil(@budget_notice)}
        class={Notice.text_class(@budget_notice)}
      >
        {Notice.label(@budget_notice)} · {@budget_notice.message}
      </box>
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

  defp primary_summary(session) do
    case Enum.find(session.participants, &(&1.kind == :primary)) do
      nil -> "Assistant setup required"
      participant -> "#{participant.name} · #{Presentation.short_runtime_label(participant)}"
    end
  end

  defp task_participants(session), do: Enum.filter(session.participants, &(&1.kind == :task))

  defp header_context(session, terminal_width, git_branch, token_label) do
    branch = if is_binary(git_branch), do: " · " <> git_branch, else: ""

    # Breeze inline boxes abut without gutters. The workspace absorbs the
    # remaining width after the Assistant, branch, token meter, and separators.
    reserved =
      String.length(primary_summary(session)) + String.length(branch) +
        String.length(token_label) + 8

    " · " <>
      workspace_context(session.workspace, max(terminal_width - reserved, 12)) <>
      branch
  end

  defp header_token_class(class), do: "w-full text-right " <> class
  defp work_pulse_class(item), do: "text-#{Activity.color(item)}"

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
