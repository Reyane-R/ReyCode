defmodule ReyCode.TUI.WorkCommand do
  @moduledoc "Owns Operator steering and queued FollowUp command actions."

  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.SlashPalette

  @spec run(map(), String.t(), term()) :: {:noreply, map()}
  def run(term, "/steer", body) do
    room = Map.get(term.assigns.projection.rooms, term.assigns.selected_room_id)

    case room && room.active_turn_id do
      nil ->
        {:noreply, SlashPalette.close(term, "No active work to steer")}

      turn_id ->
        steer(term, turn_id, body)
    end
  end

  def run(term, "/unqueue", nil) do
    case Engine.cancel_latest_follow_up(term.assigns.selected_room_id, term.assigns.engine) do
      :ok ->
        {:noreply, SlashPalette.close(term, "Newest follow-up cancelled")}

      {:error, reason} ->
        {:noreply, SlashPalette.close(term, "Could not cancel follow-up: #{reason}")}
    end
  end

  defp steer(term, turn_id, body) do
    case Engine.steer_turn(turn_id, body, term.assigns.engine) do
      :ok ->
        {:noreply, SlashPalette.close(term, "Steering queued for the next provider round")}

      {:error, reason} ->
        {:noreply, SlashPalette.close(term, "Could not steer: #{reason}")}
    end
  end
end
