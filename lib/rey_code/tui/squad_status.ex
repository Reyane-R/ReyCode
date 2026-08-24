defmodule ReyCode.TUI.SquadStatus do
  @moduledoc """
  State, input handling, and rendering for the squad-status dashboard modal.
  """

  use Breeze.Component

  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Squad.Dashboard
  alias ReyCode.TUI.SlashPalette

  @doc "Opens the active or most recent squad dashboard for the selected room."
  @spec open(map()) :: map()
  def open(term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]

    if Dashboard.turn(room, term.assigns.projection) do
      Component.assign(term, modal: :squad_dashboard, slash: nil, notice: nil)
    else
      SlashPalette.close(term, "No squad run is available for this room")
    end
  end

  @doc "Closes squad status and restores prompt focus."
  @spec close(map()) :: map()
  def close(term) do
    term
    |> Component.assign(modal: nil, notice: nil)
    |> View.focus("prompt")
  end

  @doc "Keeps global focus unchanged while the dashboard is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Submits nothing; the dashboard is informational."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, term}

  @doc "Handles one key press while the dashboard is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the dashboard declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the squad-status dashboard."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-3 pt-2">
      <box class="inline w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Squad status</box>
        <box class="w-full text-right text-muted">#{@term.room.slug}   Esc close</box>
      </box>
      <.dashboard_body term={@term}/>
    </box>
    """
  end

  attr :term, :map, required: true

  defp dashboard_body(%{term: %{dashboard: nil}} = assigns) do
    ~H"""
    <box class="pt-3 text-muted">No squad run is available for this room.</box>
    """
  end

  defp dashboard_body(assigns) do
    ~H"""
    <.scroll
      id="squad-dashboard"
      class="h-full w-full border-none overflow-scroll mute-scrollbar-40 pt-1"
    >
      <box class="inline w-full">
        <box class="font-bold">{@term.dashboard.turn.outcome || @term.dashboard.turn.status}</box>
        <box class="w-full text-right text-primary">
          {@term.dashboard.turn.squad.phase}  /  cycle {@term.dashboard.turn.squad.cycle}
        </box>
      </box>
      <box class="text-muted">
        rework {@term.dashboard.turn.squad.rework_count}/{@term.dashboard.turn.squad.rework_budget}  / {Dashboard.usage_label(@term.dashboard.usage)}
      </box>
      <box class="pt-2 text-muted">PHASES</box>
      <box
        :for={{phase, index} <- @term.dashboard.phases}
        class={Dashboard.phase_class(index, @term.dashboard.turn)}
      >
        {Dashboard.phase_marker(index, @term.dashboard.turn)} {phase.id}{Dashboard.gate_label(phase)}
      </box>
      <box class="pt-2 text-muted">GATE HISTORY</box>
      <box
        :if={@term.dashboard.resolutions == [] and @term.dashboard.reviews == []}
        class="text-muted"
      >
        No gate resolutions recorded.
      </box>
      <box :for={review <- @term.dashboard.reviews} class="w-full overflow-hidden">
        <box class="font-bold text-warning">{Dashboard.review_label(review)}</box>
        <box :if={review.recommendation.reasons != []} class="pl-2 text-muted w-full overflow-hidden">
          {Enum.join(review.recommendation.reasons, "; ")}
        </box>
      </box>
      <box :for={resolution <- @term.dashboard.resolutions} class="w-full overflow-hidden">
        <box class="font-bold">{Dashboard.resolution_label(resolution)}</box>
        <box :if={resolution.reasons != []} class="pl-2 text-muted w-full overflow-hidden">
          {Enum.join(resolution.reasons, "; ")}
        </box>
      </box>
      <box class="pt-2 text-muted">ARTIFACTS</box>
      <box :if={@term.dashboard.artifacts == []} class="text-muted">No artifacts recorded.</box>
      <box :for={artifact <- @term.dashboard.artifacts} class="w-full pb-1 overflow-hidden">
        <box class="font-bold">{Dashboard.artifact_label(artifact)}</box>
        <box class="pl-2 text-muted w-full overflow-hidden">{artifact.summary}</box>
        <box :if={artifact.blockers != []} class="pl-2 text-error w-full overflow-hidden">
          blockers: {Enum.join(artifact.blockers, "; ")}
        </box>
      </box>
      <box class="pt-2 text-muted">RETRIES</box>
      <box :if={@term.dashboard.retries == []} class="text-muted">No retries recorded.</box>
      <box :for={retry <- @term.dashboard.retries} class="w-full overflow-hidden">
        {Dashboard.retry_label(retry)}
      </box>
      <box class="pt-2 text-muted">OWNER DIRECTIVES</box>
      <box :if={@term.dashboard.directives == []} class="text-muted">No directives recorded.</box>
      <box :for={directive <- @term.dashboard.directives} class="w-full pb-1 overflow-hidden">
        <box class="font-bold">{directive.phase} / cycle {directive.cycle}</box>
        <box class="pl-2 text-muted w-full overflow-hidden">{directive.text}</box>
      </box>
    </.scroll>
    """
  end
end
