defmodule ReyCode.TUI.WorkCommand do
  @moduledoc "Owns Operator steering and queued FollowUp command actions."

  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.{Notice, Recovery, SlashPalette}

  @spec run(map(), String.t(), term()) :: {:noreply, map()}
  def run(term, "/steer", body) do
    session = Map.get(term.assigns.projection.sessions, term.assigns.selected_session_id)

    case session && session.active_turn_id do
      nil ->
        {:noreply, SlashPalette.close(term, Notice.new(:info, "No active work to steer"))}

      turn_id ->
        steer(term, turn_id, body)
    end
  end

  def run(term, "/dequeue", nil), do: Recovery.dequeue_latest(term)

  defp steer(term, turn_id, body) do
    case Engine.steer_turn(turn_id, body, term.assigns.engine) do
      :ok ->
        {:noreply,
         SlashPalette.close(
           term,
           Notice.new(:success, "Steering queued for the next provider round")
         )}

      {:error, reason} ->
        {:noreply, SlashPalette.close(term, Notice.new(:error, "Could not steer: #{reason}"))}
    end
  end
end
