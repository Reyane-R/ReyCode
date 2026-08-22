defmodule ReyCode.TUI.ToolReview do
  @moduledoc "State transitions for owner review of a pending tool request."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.SlashPalette

  @options [:approve, :deny]

  @spec initial() :: map()
  def initial, do: %{invocation_id: nil, review: nil, index: 0}

  @spec options() :: [atom()]
  def options, do: @options

  @spec open(map()) :: map()
  def open(term) do
    room = term.assigns.projection.rooms[term.assigns.selected_room_id]
    invocation = pending_invocation(term.assigns.projection, room && room.active_turn_id)

    if invocation do
      Component.assign(term,
        modal: :tool_review,
        slash: nil,
        tool_review: %{
          invocation_id: invocation.id,
          review: invocation.pending_tool_review,
          index: 0
        },
        notice: nil
      )
    else
      SlashPalette.close(term, "No tool request is awaiting approval")
    end
  end

  @spec move(map(), integer()) :: map()
  def move(term, offset) do
    index = Integer.mod(term.assigns.tool_review.index + offset, length(@options))
    Component.assign(term, tool_review: %{term.assigns.tool_review | index: index})
  end

  @spec choose(map(), String.t()) :: {:noreply, map()}
  def choose(term, key) do
    index = %{"a" => 0, "d" => 1}[String.downcase(key)]

    term
    |> Component.assign(tool_review: %{term.assigns.tool_review | index: index})
    |> submit()
  end

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    review_state = term.assigns.tool_review
    decision = Enum.at(@options, review_state.index)
    run_id = review_state.review && review_state.review.request_id

    case Engine.resolve_tool_run(
           review_state.invocation_id,
           run_id,
           decision,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           tool_review: initial(),
           notice: resolution_notice(decision)
         )
         |> View.focus("prompt")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not resolve tool request: #{reason}")}
    end
  end

  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(modal: nil, tool_review: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp pending_invocation(_projection, nil), do: nil

  defp pending_invocation(projection, turn_id) do
    projection.invocations
    |> Map.values()
    |> Enum.find(fn invocation ->
      invocation.turn_id == turn_id and not is_nil(invocation.pending_tool_review)
    end)
  end

  defp resolution_notice(:approve), do: "Tool request approved"
  defp resolution_notice(:deny), do: "Tool request denied"
end
