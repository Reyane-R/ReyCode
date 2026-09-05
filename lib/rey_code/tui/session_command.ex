defmodule ReyCode.TUI.SessionCommand do
  @moduledoc "Owns Session fork, rewind, and export command actions."

  alias ReyCode.Orchestration.Engine
  alias ReyCode.SessionExport
  alias ReyCode.TUI.{Notice, SlashPalette, State}

  @spec run(map(), String.t(), term()) :: {:noreply, map()}
  def run(term, "/fork", nil), do: fork(term, term.assigns.projection.sequence)

  def run(term, "/rewind", sequence) do
    case Integer.parse(sequence || "") do
      {value, ""} ->
        fork(term, value)

      _other ->
        {:noreply,
         SlashPalette.close(
           term,
           Notice.new(:warning, "Rewind requires a durable sequence number")
         )}
    end
  end

  def run(term, "/export", nil) do
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]
    path = Path.join([session.workspace, ".reycode", "exports", session.id <> ".md"])

    case SessionExport.write(term.assigns.projection, session.id, path, :markdown) do
      :ok ->
        {:noreply, SlashPalette.close(term, Notice.new(:success, "Session exported to #{path}"))}

      {:error, reason} ->
        {:noreply,
         SlashPalette.close(term, Notice.new(:error, "Could not export Session: #{reason}"))}
    end
  end

  defp fork(term, sequence) do
    case Engine.fork_session(term.assigns.selected_session_id, sequence, term.assigns.engine) do
      {:ok, session_id} ->
        next =
          term
          |> SlashPalette.close(Notice.new(:success, "Session forked"))
          |> State.select_session(session_id)

        {:noreply, next}

      {:error, reason} ->
        {:noreply,
         SlashPalette.close(term, Notice.new(:error, "Could not fork Session: #{reason}"))}
    end
  end
end
