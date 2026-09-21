defmodule ReyCode.TUI.Components.MainScreen do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  import ReyCode.TUI.Components.MainScreen.Timeline, only: [timeline: 1]
  import ReyCode.TUI.OperatorQuestion, only: [question_panel: 1]

  import ReyCode.TUI.Components.HUD,
    only: [hero: 1, rail: 1, home_rail: 1, scan: 1, boundary: 1, glyph: 2]

  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.{Action, Activity, Cancellation, Notice, State, Verification}
  attr :modal, :any, required: true
  attr :home, :boolean, required: true
  attr :sessions, :list, required: true
  attr :mode, :atom, required: true
  attr :session, :map, required: true
  attr :projection, :map, required: true
  attr :selected_session_id, :string, required: true
  attr :operator_question, :map, required: true
  attr :providers, :map, required: true
  attr :messages, :list, required: true
  attr :activity, :map, required: true
  attr :wall, :map, required: true
  attr :activity_frame, :string, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :draft, :string, required: true
  attr :notice, :any, required: true
  attr :composer_status, :map, required: true
  attr :token_label_class, :string, required: true
  attr :update_notice, :any, required: true
  attr :text_selection, :any, default: nil
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true
  attr :rail_width, :integer, required: true
  attr :content_width, :integer, required: true

  attr :terminal_width, :integer, required: true
  attr :terminal_height, :integer, required: true

  def main_screen(assigns) do
    input_height =
      State.composer_height(
        Map.get(assigns, :draft, ""),
        Map.get(assigns, :modal),
        assigns.terminal_height
      )

    footer_height =
      if Map.get(assigns, :modal) == :operator_question, do: 14, else: input_height + 4

    bottom = max(assigns.terminal_height - footer_height, 0)
    header_height = if assigns.session.verified_change, do: 8, else: 4

    assigns =
      assign(assigns,
        background_motion:
          Map.get(assigns, :motion, false) == true and is_nil(Map.get(assigns, :modal)),
        home_clip: {0, 0, assigns.content_width, bottom},
        home_rail_clip: {assigns.content_width, 0, assigns.terminal_width, bottom},
        timeline_clip: {0, header_height, assigns.content_width, bottom},
        rail_clip: {assigns.content_width, header_height, assigns.terminal_width, bottom},
        screen_clip: {0, 0, assigns.terminal_width, assigns.terminal_height}
      )

    ~H"""
    <box :if={@modal in [nil, :slash, :operator_question]} class="w-screen h-screen bg">
      <box class={content_class(@home)}>
        <box :if={@home} class="inline h-full w-full overflow-hidden">
          <box class="h-full" style={%{width: @content_width}}>
            <.home_panel
              session={@session}
              recent_session_rows={@recent_session_rows}
              composer_status={@composer_status}
              update_notice={@update_notice}
              terminal_width={@content_width}
              terminal_height={@terminal_height}
              motion={@background_motion}
              ascii={@ascii}
              draft={@draft}
              clip={@home_clip}
            />
          </box>
          <.home_rail
            :if={@rail_width > 0}
            session={@session}
            motion={@background_motion}
            ascii={@ascii}
            clip={@home_rail_clip}
          />
        </box>
        <.session_header
          :if={session_visible?(@home)}
          session={@session}
          projection={@projection}
          activity={@activity}
          wall={@wall}
          activity_frame={@activity_frame}
          git_branch={@git_branch}
          question_label={@question_label}
          update_notice={@update_notice}
          token_label={@token_label}
          token_label_class={@token_label_class}
          terminal_width={@terminal_width}
          motion={@background_motion}
          ascii={@ascii}
        />
        <box :if={session_visible?(@home)} class="inline h-full w-full overflow-hidden">
          <box class="h-full" style={%{width: @content_width}}>
            <.timeline
              messages={@messages}
              timeline_id={@timeline_id}
              message_width={@message_width}
              activity_frame={@activity_frame}
              terminal_height={@terminal_height}
              challenge_enabled={is_nil(@session.verified_change)}
              text_selection={@text_selection}
              motion={@background_motion}
              ascii={@ascii}
              clip={@timeline_clip}
            />
          </box>
          <.rail
            :if={@rail_width > 0}
            session={@session}
            activity={@activity}
            wall={@wall}
            token_label={@token_label}
            motion={@background_motion}
            ascii={@ascii}
            clip={@rail_clip}
          />
        </box>
        <.composer
          :if={@modal != :operator_question}
          modal={@modal}
          terminal_height={@terminal_height}
          session={@session}
          draft={@draft}
          notice={@notice}
          composer_status={@composer_status}
          motion={@background_motion}
          ascii={@ascii}
          activity={@activity}
          wall={@wall}
          terminal_width={@terminal_width}
        />
        <.question_panel :if={@modal == :operator_question} term={assigns}/>
        <.slash_palette
          modal={@modal}
          slash_rows={@slash_rows}
          slash_style={@slash_style}
          slash_empty_label={@slash_empty_label}
          motion={@motion}
          ascii={@ascii}
          clip={@screen_clip}
        />
      </box>
    </box>
    """
  end

  attr :session, :map, required: true
  attr :recent_session_rows, :list, required: true
  attr :composer_status, :map, required: true
  attr :update_notice, :any, required: true
  attr :terminal_width, :integer, required: true
  attr :terminal_height, :integer, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true
  attr :draft, :string, required: true
  attr :clip, :any, required: true

  defp home_panel(assigns) do
    ~H"""
    <.scroll id="home-scroll" class="h-full w-full overflow-scroll mute-scrollbar-40 px-2">
      <.hero
        width={@terminal_width}
        height={@terminal_height}
        motion={@motion}
        ascii={@ascii}
        skip={@draft != ""}
        clip={@clip}
      />
      <box class="pt-1 inline w-full border-b border-accent pb-1">
        <box class="font-bold text-accent">REYCODE</box>
        <box class="pl-2 text-primary">// AI workbench</box>
        <.scan
          :if={@terminal_height < 30 and @terminal_width >= 60}
          id="compact-home-scan"
          width={16}
          motion={@motion}
          ascii={@ascii}
          class="text-accent"
          clip={@clip}
        />
        <box :if={@update_notice} class={"w-full text-right " <> Notice.text_class(@update_notice)}>
          {@update_notice.message}
        </box>
      </box>
      <box class="pt-1 text-secondary">{glyph(:corner, @ascii)} 01 / Workspace</box>
      <box class="font-bold">{compact_home(@session.workspace)}</box>
      <box class="pt-1 text-secondary">{glyph(:corner, @ascii)} 02 / Assistant</box>
      <box class="inline w-full">
        <box
          id="choose-model-home"
          implicit={Action}
          focusable
          br-change="configure_models"
          class="font-bold focus:text-secondary"
        >
          {primary_summary(@session)}
        </box>
        <box
          :if={@composer_status.label != "Ready"}
          class={"w-full text-right " <> @composer_status.class}
        >
          {@composer_status.label}
        </box>
      </box>
      <box class="pt-1 text-secondary">{glyph(:corner, @ascii)} 03 / Quick start</box>
      <box :if={connect_first?(@composer_status)} id="connect-setup" class="text-primary">
        /connect  Choose a model provider
      </box>
      <box
        :if={not connect_first?(@composer_status)}
        id="verification-setup"
        implicit={Action}
        focusable
        br-change="verification_setup"
        class="text-primary"
      >
        /verify  Verify an isolated change
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/</box>
        <box>Browse actions · Ctrl+P</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">@file</box>
        <box>Attach workspace context</box>
      </box>
      <box class="inline w-full">
        <box class="w-12 text-muted">/resume</box>
        <box>Continue a previous session</box>
      </box>
      <box class="pt-1 text-muted">
        Find task agents, review tools, and settings in the action menu.
      </box>
      <box class="pt-1 text-secondary">
        {glyph(:corner, @ascii)} 04 / Teammates · {length(task_participants(@session))}
      </box>
      <box :if={task_participants(@session) == []} class="text-muted">
        None yet. Create one when a responsibility repeats.
      </box>
      <box :for={participant <- task_participants(@session)}>
        {participant.name} · {Presentation.current_assignment_label(participant)}
      </box>
      <box class="pt-1 text-secondary">
        {glyph(:corner, @ascii)} 05 / Recent sessions · {length(@recent_session_rows)}
      </box>
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
  attr :wall, :map, required: true
  attr :question_label, :string, required: true
  attr :update_notice, :any, required: true
  attr :token_label_class, :string, required: true
  attr :terminal_width, :integer, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true

  defp session_header(assigns) do
    ~H"""
    <box
      class={if @session.verified_change do
      "h-8 w-full bg-surface border-b border-accent px-2"
    else
      "h-4 w-full bg-surface border-b border-accent px-2"
    end}
    >
      <box class="inline w-full overflow-hidden">
        <box class="font-bold text-identity">{glyph(:corner, @ascii)} REYCODE // </box>
        <.boundary
          id="session-scan"
          wall={@wall}
          width={min(max(@terminal_width - 34, 1), 80)}
          motion={@motion}
          ascii={@ascii}
          clip={{0, 0, @terminal_width, 1}}
        />
        <box class="text-muted"> SESSION</box>
      </box>
      <box class="inline w-full overflow-hidden">
        <box
          id="choose-model"
          implicit={Action}
          focusable
          br-change="configure_models"
          class="font-bold text-primary focus:text-secondary"
        >
          {primary_summary(@session)}
        </box>
        <box class="h-1 overflow-hidden text-muted">
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
      <box :if={@session.verified_change} class="text-primary">
        {Verification.summary(@session, @projection)}
      </box>
      <box :if={@session.verified_change} class="text-warning">
        {Verification.source_label(@session)}
      </box>
      <box :if={@session.verified_change} class="inline w-full">
        <box
          id="verification-review"
          implicit={Action}
          focusable
          br-change="verification_review"
          class="pr-2 text-primary"
        >
          /changes Review
        </box>
        <box
          :if={Cancellation.verified_active?(@session)}
          id="verification-cancel"
          implicit={Action}
          focusable
          br-change="verification_cancel"
          class="pr-2 text-warning"
        >
          /cancel Stop
        </box>
        <box
          id="verification-tools"
          implicit={Action}
          focusable
          br-change="verification_tools"
          class="pr-2 text-muted"
        >
          /tools
        </box>
        <box
          id="verification-question"
          implicit={Action}
          focusable
          br-change="verification_question"
          class="text-muted"
        >
          /answer
        </box>
      </box>
    </box>
    """
  end

  attr :draft, :string, required: true
  attr :notice, :any, required: true
  attr :composer_status, :map, required: true
  attr :wall, :map, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true
  attr :activity, :map, required: true
  attr :terminal_width, :integer, required: true

  defp composer(assigns) do
    assigns =
      Map.put(
        assigns,
        :input_height,
        State.composer_height(assigns.draft, Map.get(assigns, :modal), assigns.terminal_height)
      )

    ~H"""
    <box
      class={"h-#{@input_height + 4} w-full bg-surface border-t border-accent px-2 overflow-hidden"}
    >
      <box class="inline w-full">
        <box class="font-bold text-primary">{glyph(:corner, @ascii)} Message Assistant</box>
        <.boundary
          :if={@terminal_width >= 72}
          id="composer-signal"
          wall={@wall}
          width={12}
          motion={@motion}
          ascii={@ascii}
          clip={{0, 0, @terminal_width, @terminal_height}}
        />
        <box :if={is_nil(@notice)} class={"w-full text-right " <> @composer_status.class}>
          {@composer_status.label}
        </box>
        <box :if={not is_nil(@notice)} class={"w-full text-right " <> Notice.text_class(@notice)}>
          {Notice.label(@notice)}
        </box>
      </box>
      <.textarea
        id="prompt"
        textarea-value={@draft}
        textarea-placeholder="Ask anything…  / commands  @ files"
        textarea-submit-on-enter={true}
        br-change="prompt_changed"
        br-submit="prompt_submitted"
        class={"w-full h-#{@input_height} border border-secondary focus:border-primary bg-panel"}
        style={%{border: ReyCode.TUI.Components.HUD.frame(@ascii)}}
      />
      <box :if={is_nil(@notice)} class="text-muted">
        Enter {State.send_label(@session)} · /steer · Shift+Enter new line · ↑↓ history
      </box>
      <box :if={not is_nil(@notice)} class={Notice.text_class(@notice)}>
        {Notice.label(@notice)} · {@notice.message}
      </box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :slash_rows, :list, required: true
  attr :slash_style, :map, required: true

  attr :slash_empty_label, :string, required: true
  attr :clip, :any, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true

  defp slash_palette(assigns) do
    ~H"""
    <box
      :if={@modal == :slash}
      class={if @slash_style.height > 1 do
      "bg-panel border-l border-r border-t border-accent overflow-hidden layer-40"
    else
      "bg-panel overflow-hidden layer-40"
    end}
      style={@slash_style}
    >
      <box
        :if={@slash_style.height >= 3}
        class="h-1 w-full px-1 text-secondary overflow-hidden inline"
      >
        <box>
          {if @slash_empty_label == "No matching files" do
            "Files"
          else
            "Actions"
          end} // type to search · Esc back
        </box>
        <.scan
          :if={@slash_style.width >= 72}
          id="palette-scan"
          width={16}
          motion={@motion}
          ascii={@ascii}
          clip={@clip}
        />
      </box>
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
      participant -> "#{participant.name} · #{Presentation.current_assignment_label(participant)}"
    end
  end

  defp task_participants(session), do: Enum.filter(session.participants, &(&1.kind == :task))

  # A Primary without a usable runtime cannot answer anything; connection
  # outranks every other quick-start action until it is resolved.
  defp connect_first?(%{label: "Ready"}), do: false
  defp connect_first?(%{label: "Checking providers…"}), do: false
  defp connect_first?(_status), do: true

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

  defp header_token_class(class), do: "w-full h-1 overflow-hidden text-right " <> class
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
