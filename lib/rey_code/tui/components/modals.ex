defmodule ReyCode.TUI.Components.Modals do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  alias ReyCode.Orchestration.Squad.Dashboard
  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.Settings

  attr :modal, :any, required: true
  attr :new_room, :map, required: true
  attr :settings, :map, required: true
  attr :room, :map, required: true
  attr :mode, :atom, required: true
  attr :providers, :map, required: true
  attr :terminal_width, :integer, required: true
  attr :terminal_height, :integer, required: true
  attr :notice, :any, required: true
  attr :cancel_turn_id, :any, required: true
  attr :dashboard, :any, required: true
  attr :directive, :map, required: true
  attr :gate_review, :map, required: true
  attr :gate_review_options, :list, required: true
  attr :tool_review, :map, required: true
  attr :tool_review_options, :list, required: true

  def modals(assigns) do
    ~H"""
    <.new_room_modal modal={@modal} new_room={@new_room}/>
    <.settings_modal
      modal={@modal}
      settings={@settings}
      room={@room}
      mode={@mode}
      providers={@providers}
      terminal_height={@terminal_height}
      notice={@notice}
    />
    <.workspace_modal modal={@modal} room={@room} terminal_width={@terminal_width}/>
    <.cancel_modal modal={@modal} cancel_turn_id={@cancel_turn_id} notice={@notice}/>
    <.dashboard_modal modal={@modal} room={@room} dashboard={@dashboard}/>
    <.directive_modal modal={@modal} directive={@directive} notice={@notice}/>
    <.gate_review_modal
      modal={@modal}
      gate_review={@gate_review}
      gate_review_options={@gate_review_options}
      notice={@notice}
    />
    <.tool_review_modal
      modal={@modal}
      tool_review={@tool_review}
      tool_review_options={@tool_review_options}
    />
    """
  end

  attr :modal, :any, required: true
  attr :new_room, :map, required: true

  defp new_room_modal(assigns) do
    ~H"""
    <box :if={@modal == :new_room} class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Create a project room</box>
        <box class="text-muted">Rooms keep project context, messages, and agent work together.</box>
      </box>
      <box class="pt-3 text-muted">ROOM NAME</box>
      <box class="w-full pt-1">
        <.textarea
          id="new-room-name"
          textarea-value={@new_room.name}
          textarea-placeholder="Payments rewrite"
          textarea-submit-on-enter={true}
          br-change="new_room_changed"
          br-submit="new_room_submitted"
          class="w-full h-3"
        />
      </box>
      <box class="pt-2 text-muted">WORKSPACE</box>
      <box class="w-full overflow-hidden">{@new_room.workspace}</box>
      <box class="pt-2 text-muted">Enter create   Esc cancel</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :settings, :map, required: true
  attr :room, :map, required: true
  attr :mode, :atom, required: true
  attr :providers, :map, required: true
  attr :terminal_height, :integer, required: true
  attr :notice, :any, required: true

  defp settings_modal(assigns) do
    ~H"""
    <box :if={@modal == :settings} class="w-screen h-screen bg px-4 pt-2">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Configure room agents</box>
        <box class="w-full text-right text-muted">{settings_header_controls(@settings.step)}</box>
      </box>
      <box class="pt-1 text-muted"># {@room.slug}  /  {settings_step_label(@settings.step)}</box>
      <box :if={@settings.step == :participants} class="pt-2 w-full">
        <box class="font-bold">Who should use this runtime?</box>
        <box
          :for={{option, index} <- Enum.with_index(Settings.participant_options(@room, @mode))}
          class={settings_option_class(index, @settings.index)}
        >
          {settings_marker(index, @settings.index)} {option.label}
        </box>
      </box>
      <box :if={@settings.step == :providers} class="pt-2 w-full">
        <box class="font-bold">Select a runtime</box>
        <box
          :for={{provider, index} <- Enum.with_index(Settings.provider_options(@providers))}
          class={settings_option_class(index, @settings.index)}
        >
          {settings_marker(index, @settings.index)} {provider.name}  {Presentation.status_label(provider)}
        </box>
        <box class="pt-2 text-muted">
          {Presentation.selection_help(Enum.at(Settings.provider_options(@providers), @settings.index))}
        </box>
      </box>
      <box :if={@settings.step == :models} class="pt-2 w-full">
        <box class="font-bold">Select a model</box>
        <box class="text-muted">Filter: {@settings.query}  (type to search, Backspace clears)</box>
        <box
          :for={{model, index} <- Settings.visible_models(
      @providers,
      @settings,
      @terminal_height
    )}
          class={settings_option_class(index, @settings.index)}
        >
          {settings_marker(index, @settings.index)} {model}
        </box>
      </box>
      <box :if={not is_nil(@notice)} class="pt-2 text-error">{@notice}</box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :room, :map, required: true
  attr :terminal_width, :integer, required: true

  defp workspace_modal(assigns) do
    ~H"""
    <box :if={@modal == :workspace} class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Room workspace</box>
        <box class="text-muted">OpenCode runs with this exact working directory.</box>
      </box>
      <box class="pt-3 text-muted">ABSOLUTE PATH</box>
      <box class="pt-1 w-full">{wrap_workspace(@room.workspace, @terminal_width - 8)}</box>
      <box class="pt-3 text-muted">Esc close</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :cancel_turn_id, :any, required: true
  attr :notice, :any, required: true

  defp cancel_modal(assigns) do
    ~H"""
    <box :if={@modal == :cancel} class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-error">Cancel running turn</box>
        <box class="text-muted">This stops active agent work and marks the turn cancelled.</box>
      </box>
      <box class="pt-3 text-muted">TURN</box>
      <box class="pt-1 w-full">{@cancel_turn_id}</box>
      <box :if={not is_nil(@notice)} class="pt-2 text-error">{@notice}</box>
      <box class="pt-3 text-muted">Enter cancel   Esc keep running</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :room, :map, required: true
  attr :dashboard, :any, required: true

  defp dashboard_modal(assigns) do
    ~H"""
    <box :if={@modal == :squad_dashboard} class="w-screen h-screen bg px-3 pt-2">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Squad status</box>
        <box class="w-full text-right text-muted"># {@room.slug}   Esc close</box>
      </box>
      <box :if={is_nil(@dashboard)} class="pt-3 text-muted">
        No squad run is available for this room.
      </box>
      <.scroll
        :if={not is_nil(@dashboard)}
        id="squad-dashboard"
        class="h-full w-full border-none overflow-scroll mute-scrollbar-40 pt-1"
      >
        <box class="inline w-full">
          <box class="font-bold">{@dashboard.turn.status}</box>
          <box class="w-full text-right text-primary">
            {@dashboard.turn.squad.phase}  /  cycle {@dashboard.turn.squad.cycle}
          </box>
        </box>
        <box class="text-muted">
          rework {@dashboard.turn.squad.rework_count}/{@dashboard.turn.squad.rework_budget}  /  {Dashboard.usage_label(@dashboard.usage)}
        </box>
        <box class="pt-2 text-muted">PHASES</box>
        <box
          :for={{phase, index} <- @dashboard.phases}
          class={Dashboard.phase_class(index, @dashboard.turn)}
        >
          {Dashboard.phase_marker(index, @dashboard.turn)} {phase.id}{Dashboard.gate_label(phase)}
        </box>
        <box class="pt-2 text-muted">GATE HISTORY</box>
        <box :if={@dashboard.decisions == [] and @dashboard.reviews == []} class="text-muted">
          No gate decisions recorded.
        </box>
        <box :for={review <- @dashboard.reviews} class="w-full overflow-hidden">
          <box class="font-bold text-warning">{Dashboard.review_label(review)}</box>
          <box :if={review.reasons != []} class="pl-2 text-muted w-full overflow-hidden">
            {Enum.join(review.reasons, "; ")}
          </box>
        </box>
        <box :for={decision <- @dashboard.decisions} class="w-full overflow-hidden">
          <box class="font-bold">{Dashboard.decision_label(decision)}</box>
          <box :if={decision.reasons != []} class="pl-2 text-muted w-full overflow-hidden">
            {Enum.join(decision.reasons, "; ")}
          </box>
        </box>
        <box class="pt-2 text-muted">ARTIFACTS</box>
        <box :if={@dashboard.artifacts == []} class="text-muted">No artifacts recorded.</box>
        <box :for={artifact <- @dashboard.artifacts} class="w-full pb-1 overflow-hidden">
          <box class="font-bold">{Dashboard.artifact_label(artifact)}</box>
          <box class="pl-2 text-muted w-full overflow-hidden">{artifact.summary}</box>
          <box :if={artifact.blockers != []} class="pl-2 text-error w-full overflow-hidden">
            blockers: {Enum.join(artifact.blockers, "; ")}
          </box>
        </box>
        <box class="pt-2 text-muted">RETRIES</box>
        <box :if={@dashboard.retries == []} class="text-muted">No retries recorded.</box>
        <box :for={retry <- @dashboard.retries} class="w-full overflow-hidden">
          {Dashboard.retry_label(retry)}
        </box>
        <box class="pt-2 text-muted">OWNER DIRECTIVES</box>
        <box :if={@dashboard.directives == []} class="text-muted">No directives recorded.</box>
        <box :for={directive <- @dashboard.directives} class="w-full pb-1 overflow-hidden">
          <box class="font-bold">{directive.phase} / cycle {directive.cycle}</box>
          <box class="pl-2 text-muted w-full overflow-hidden">{directive.text}</box>
        </box>
      </.scroll>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :directive, :map, required: true
  attr :notice, :any, required: true

  defp directive_modal(assigns) do
    ~H"""
    <box :if={@modal == :directive} class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Steer the running squad</box>
        <box class="text-muted">Every subsequently scheduled role receives this directive.</box>
      </box>
      <box class="pt-3 text-muted">OWNER DIRECTIVE</box>
      <box class="w-full pt-1">
        <.textarea
          id="directive-text"
          textarea-value={@directive.text}
          textarea-placeholder="Constrain scope, change priority, or add project context..."
          textarea-submit-on-enter={true}
          br-change="directive_changed"
          br-submit="directive_submitted"
          class="w-full h-5"
        />
      </box>
      <box :if={not is_nil(@notice)} class="pt-2 text-error">{@notice}</box>
      <box class="pt-2 text-muted">Enter send directive   Esc cancel</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :gate_review, :map, required: true
  attr :gate_review_options, :list, required: true
  attr :notice, :any, required: true

  defp gate_review_modal(assigns) do
    ~H"""
    <box :if={@modal == :gate_review} class="w-screen h-screen bg px-4 pt-2">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Release gate review</box>
        <box class="text-muted">
          The squad leader recommends a decision; the owner is authoritative.
        </box>
      </box>
      <box class="pt-2 text-muted">LEADER RECOMMENDATION</box>
      <box class="pt-1 font-bold text-warning">{@gate_review.review.decision}</box>
      <box :if={@gate_review.review.reasons == []} class="pt-1 text-muted">No reasons supplied.</box>
      <box
        :for={reason <- @gate_review.review.reasons}
        class="pt-1 text-muted w-full overflow-hidden"
      >
        - {reason}
      </box>
      <box class="pt-3 text-muted">OWNER DECISION</box>
      <box
        :for={{decision, index} <- Enum.with_index(@gate_review_options)}
        class={gate_review_option_class(index, @gate_review.index)}
      >
        {settings_marker(index, @gate_review.index)} {decision}
      </box>
      <box :if={not is_nil(@notice)} class="pt-2 text-error">{@notice}</box>
      <box class="pt-3 text-muted">A approve   R rework   B abort   Enter confirm   Esc close</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :tool_review, :map, required: true
  attr :tool_review_options, :list, required: true

  defp tool_review_modal(assigns) do
    ~H"""
    <box :if={@modal == :tool_review} class="w-screen h-screen bg px-4 pt-2">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Tool approval</box>
        <box class="text-muted">This request is waiting for owner approval.</box>
      </box>
      <box class="pt-2 text-muted">TOOL</box>
      <box class="pt-1 font-bold text-warning">{@tool_review.review.tool}</box>
      <box class="pt-2 text-muted">WORKSPACE</box>
      <box class="pt-1 text-muted w-full overflow-hidden">{@tool_review.review.workspace}</box>
      <box class="pt-3 text-muted">OWNER DECISION</box>
      <box
        :for={{decision, index} <- Enum.with_index(@tool_review_options)}
        class={tool_review_option_class(index, @tool_review.index)}
      >
        {settings_marker(index, @tool_review.index)} {decision}
      </box>
      <box class="pt-3 text-muted">A approve   D deny   Enter confirm   Esc close</box>
    </box>
    """
  end

  defp settings_header_controls(:providers), do: "Esc back   R recheck"
  defp settings_header_controls(_step), do: "Esc back"

  defp wrap_workspace(path, width) do
    path
    |> String.graphemes()
    |> Enum.chunk_every(max(width, 20))
    |> Enum.map_join("\n", &Enum.join/1)
  end

  defp settings_option_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp settings_option_class(_index, _selected), do: "w-full px-1 text-muted"
  defp settings_marker(index, index), do: ">"
  defp settings_marker(_index, _selected), do: " "

  defp settings_step_label(:participants), do: "choose agents"
  defp settings_step_label(:providers), do: "choose runtime"
  defp settings_step_label(:models), do: "choose model"

  defp gate_review_option_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp gate_review_option_class(_index, _selected), do: "w-full px-1 text-muted"

  defp tool_review_option_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp tool_review_option_class(_index, _selected), do: "w-full px-1 text-muted"
end
