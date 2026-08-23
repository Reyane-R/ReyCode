defmodule ReyCode.TUI.Cancellation do
  @moduledoc """
  State, input handling, and rendering for cancelling the selected room's
  active turn.
  """

  use Breeze.Component

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

  @doc "Keeps global focus unchanged while the confirmation is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Handles one key press while the cancellation modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the cancellation modal declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the cancellation confirmation."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-error">Cancel running turn</box>
        <box class="text-muted">This stops active agent work and marks the turn cancelled.</box>
      </box>
      <box class="pt-3 text-muted">TURN</box>
      <box class="pt-1 w-full">{@term.cancel_turn_id}</box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-3 text-muted">Enter cancel   Esc keep running</box>
    </box>
    """
  end
end
