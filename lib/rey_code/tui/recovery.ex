defmodule ReyCode.TUI.Recovery do
  @moduledoc "Operator recovery actions for failed Turns and queued FollowUps."

  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.{SlashPalette, State}

  @spec retry_latest(map()) :: {:noreply, map()}
  def retry_latest(term) do
    case latest_failed_turn(term.assigns) do
      nil ->
        {:noreply, SlashPalette.close(term, "No failed Turn to retry")}

      turn ->
        case Engine.retry_turn(turn.id, term.assigns.engine) do
          {:ok, _turn_id} ->
            {:noreply, SlashPalette.close(term, "Failed Turn retried as a new linked Turn")}

          {:error, reason} ->
            {:noreply, SlashPalette.close(term, "Could not retry Turn: #{reason}")}
        end
    end
  end

  @spec dequeue_latest(map()) :: {:noreply, map()}
  def dequeue_latest(term) do
    case Engine.dequeue_latest_follow_up(term.assigns.selected_session_id, term.assigns.engine) do
      {:ok, body} ->
        next =
          term
          |> SlashPalette.close("FollowUp returned to the composer")
          |> State.assign_draft(body)

        {:noreply, next}

      {:error, reason} ->
        {:noreply, SlashPalette.close(term, "Could not dequeue FollowUp: #{reason}")}
    end
  end

  @doc "Returns the newest failed terminal Turn represented by a Session user message."
  @spec latest_failed_turn(map()) :: map() | nil
  def latest_failed_turn(%{projection: projection, selected_session_id: session_id}) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        nil

      session ->
        session.message_order
        |> Enum.reverse()
        |> Enum.map(&projection.messages[&1])
        |> Enum.filter(fn message ->
          message && Map.get(message, :role) == :user && Map.get(message, :turn_id)
        end)
        |> Enum.map(&Map.get(projection.turns, Map.get(&1, :turn_id)))
        |> Enum.find(&match?(%{status: :terminal, outcome: :failed}, &1))
    end
  end
end
