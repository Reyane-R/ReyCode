defmodule ReyCode.TUI.Directive do
  @moduledoc """
  State, input handling, and rendering for steering a running squad.
  """

  use Breeze.Component

  import Breeze.Blocks, except: [modal: 1]

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

  @doc "Handles one key press while the directive modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}
  @doc "Handles the modal's textarea change and submit events."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("directive_changed", %{value: value}, term) do
    {:noreply, change(term, value)}
  end

  def handle_event("directive_submitted", %{value: value}, term), do: submit_value(term, value)
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the squad-directive modal."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Steer the running squad</box>
        <box class="text-muted">Every subsequently scheduled role receives this directive.</box>
      </box>
      <box class="pt-3 text-muted">OWNER DIRECTIVE</box>
      <box class="w-full pt-1">
        <.textarea
          id="directive-text"
          textarea-value={@term.directive.text}
          textarea-placeholder="Constrain scope, change priority, or add project context..."
          textarea-submit-on-enter={true}
          br-change="directive_changed"
          br-submit="directive_submitted"
          class="w-full h-5"
        />
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">Enter send directive   Esc cancel</box>
    </box>
    """
  end
end
