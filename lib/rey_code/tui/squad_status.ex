defmodule ReyCode.TUI.SquadStatus do
  @moduledoc "State transitions for the squad-status dashboard modal."

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
end
