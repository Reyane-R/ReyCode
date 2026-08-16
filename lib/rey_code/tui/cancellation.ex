defmodule ReyCode.TUI.Cancellation do
  @moduledoc "State transitions for cancelling the selected room's active turn."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.SlashPalette

  @doc "Opens cancellation confirmation for the active turn, if one exists."
  @spec open(map()) :: map()
  def open(term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]

    case room.active_turn_id do
      nil ->
        SlashPalette.close(term, "No running turn to cancel")

      turn_id ->
        Component.assign(term, modal: :cancel, slash: nil, cancel_turn_id: turn_id, notice: nil)
    end
  end

  @doc "Cancels the selected turn and closes the confirmation on success."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    case Engine.cancel_turn(term.assigns.cancel_turn_id, "Cancelled by user", term.assigns.engine) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(modal: nil, cancel_turn_id: nil, notice: "Turn cancelled")
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not cancel turn: #{reason}")}
    end
  end

  @doc "Keeps the active turn running and closes the confirmation."
  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(modal: nil, cancel_turn_id: nil, notice: nil)
    |> View.focus("prompt")
  end
end
