defmodule ReyCode.TUI.AnswerCopy do
  @moduledoc "Copies one visible answer's Markdown, excluding transcript controls and activity."

  alias Breeze.Component
  alias ReyCode.TUI.{Clipboard, Notice}
  alias ReyCode.TUI.Components.MainScreen.Timeline

  @spec run(map(), String.t()) :: {:noreply, map()}
  def run(term, message_id) do
    projection = term.assigns.projection
    session = projection.sessions[term.assigns.selected_session_id]
    message = projection.messages[message_id]

    if session && message && message_id in session.message_order && message.role == :assistant &&
         message.body != "" do
      text =
        Timeline.answer_text(%{
          role: message.role,
          status: message.status,
          turn: projection.turns[message.turn_id],
          invocation: projection.invocations[message.invocation_id],
          body: message.body
        })

      copy = Map.get(term.assigns, :answer_copy, &Clipboard.copy/1)

      notice =
        case copy.(text) do
          :ok -> Notice.new(:success, "Answer copied")
          {:error, reason} -> Notice.new(:error, "Could not copy answer: #{inspect(reason)}")
        end

      {:noreply, Component.assign(term, notice: notice)}
    else
      {:noreply,
       Component.assign(term,
         notice: Notice.new(:warning, "Answer is no longer available to copy")
       )}
    end
  end
end
