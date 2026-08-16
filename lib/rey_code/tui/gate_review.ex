defmodule ReyCode.TUI.GateReview do
  @moduledoc "State transitions for owner review of a squad release gate."

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

    case Engine.resolve_gate(
           term.assigns.gate_review.turn_id,
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
end
