defmodule ReyCode.TUI.GateReview do
  @moduledoc """
  State, input handling, and rendering for owner review of a squad release
  gate.
  """

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.SlashPalette

  @options [:approve, :rework, :abort]

  @doc "Returns empty release-gate review state."
  @spec initial() :: map()
  def initial, do: %{turn_id: nil, review: nil, index: 0}

  @doc "Returns owner decisions in display and keyboard order."
  @spec options() :: [atom()]
  def options, do: @options

  @doc "Opens an awaiting release-gate review for the active turn."
  @spec open(map()) :: map()
  def open(term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]
    turn = term.assigns.projection.turns[room.active_turn_id]
    review = turn && turn.squad && Map.get(turn.squad, :pending_review)

    if review do
      Component.assign(term,
        modal: :gate_review,
        slash: nil,
        gate_review: %{turn_id: turn.id, review: review, index: 0},
        notice: nil
      )
    else
      SlashPalette.close(term, "No release gate is awaiting owner review")
    end
  end

  @doc "Moves the selected decision by an offset, wrapping at either end."
  @spec move(map(), integer()) :: map()
  def move(term, offset) do
    index = Integer.mod(term.assigns.gate_review.index + offset, length(@options))
    Component.assign(term, gate_review: %{term.assigns.gate_review | index: index})
  end

  @doc "Selects the decision bound to a shortcut and immediately submits it."
  @spec choose(map(), String.t()) :: {:noreply, map()}
  def choose(term, key) do
    index = %{"a" => 0, "r" => 1, "b" => 2}[String.downcase(key)]

    term
    |> Component.assign(gate_review: %{term.assigns.gate_review | index: index})
    |> submit()
  end

  @doc "Resolves the release gate with the selected owner decision."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    decision = Enum.at(@options, term.assigns.gate_review.index)
    review_id = Map.get(term.assigns.gate_review.review, :review_id)

    case Engine.resolve_gate(
           term.assigns.gate_review.turn_id,
           review_id,
           decision,
           nil,
           [],
           term.assigns.engine
         ) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           gate_review: initial(),
           notice: resolution_notice(decision)
         )
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not resolve release gate: #{reason}")}
    end
  end

  @doc "Closes the review without resolving the gate."
  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(modal: nil, gate_review: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp resolution_notice(:approve), do: "Release approved"
  defp resolution_notice(:rework), do: "Release returned for rework"
  defp resolution_notice(:abort), do: "Release aborted"

  @doc "Keeps global focus unchanged while the review is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Handles one key press while the review modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, move(term, offset)}
  end

  def handle_input(key, term) when key in ["a", "A", "r", "R", "b", "B"], do: choose(term, key)
  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the review declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the release-gate review modal."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-2">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Release gate review</box>
        <box class="text-muted">
          The squad leader recommends a decision; the owner is authoritative.
        </box>
      </box>
      <box class="pt-2 text-muted">LEADER RECOMMENDATION</box>
      <box class="pt-1 font-bold text-warning">{@term.gate_review.review.decision}</box>
      <box :if={@term.gate_review.review.reasons == []} class="pt-1 text-muted">
        No reasons supplied.
      </box>
      <box
        :for={reason <- @term.gate_review.review.reasons}
        class="pt-1 text-muted w-full overflow-hidden"
      >
        - {reason}
      </box>
      <box class="pt-3 text-muted">OWNER DECISION</box>
      <box
        :for={{decision, index} <- Enum.with_index(@term.gate_review_options)}
        class={row_class(index, @term.gate_review.index)}
      >
        {marker(index, @term.gate_review.index)} {decision}
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-3 text-muted">A approve   R rework   B abort   Enter confirm   Esc close</box>
    </box>
    """
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"

  defp row_class(_index, _selected), do: "w-full px-1 text-muted"

  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
