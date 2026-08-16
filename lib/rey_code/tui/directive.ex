defmodule ReyCode.TUI.Directive do
  @moduledoc "State transitions for steering a running squad."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Orchestration.Squad.Dashboard
  alias ReyCode.TUI.SlashPalette

  @doc "Returns empty directive form state."
  @spec initial() :: map()
  def initial, do: %{turn_id: nil, text: ""}

  @doc "Opens the directive modal for a running squad turn."
  @spec open(map()) :: map()
  def open(term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]
    turn = term.assigns.projection.turns[room.active_turn_id]

    if Dashboard.squad_turn?(turn) and turn.status == :running do
      term
      |> Component.assign(
        modal: :directive,
        slash: nil,
        directive: %{turn_id: turn.id, text: ""},
        notice: nil
      )
      |> View.focus("directive-text")
    else
      SlashPalette.close(term, "No running squad is available to steer")
    end
  end

  @doc "Keeps focus on the directive textarea."
  @spec focus(map()) :: map()
  def focus(term), do: View.focus(term, "directive-text")

  @doc "Updates directive text without changing its target turn."
  @spec change(map(), String.t()) :: map()
  def change(term, value) do
    Component.assign(term, directive: %{term.assigns.directive | text: value})
  end

  @doc "Submits directive text received directly from the textarea event."
  @spec submit_value(map(), String.t()) :: {:noreply, map()}
  def submit_value(term, value), do: term |> change(value) |> submit()

  @doc "Adds the directive and closes the modal on success."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    case Engine.add_squad_directive(
           term.assigns.directive.turn_id,
           term.assigns.directive.text,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           directive: initial(),
           notice: "Squad directive added"
         )
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not add directive: #{reason}")}
    end
  end

  @doc "Cancels directive entry and restores prompt focus."
  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(modal: nil, directive: initial(), notice: nil)
    |> View.focus("prompt")
  end
end
