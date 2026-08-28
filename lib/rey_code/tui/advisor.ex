defmodule ReyCode.TUI.Advisor do
  @moduledoc "Explicit opt-in advisory review through a configured Advisor task Participant."

  alias Breeze.Component
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.SlashPalette

  @default_brief "Review the current Session's latest work. Identify risks, missing tests, and concrete corrections. Return recommendations only; do not change files."

  @spec run(map(), String.t() | nil) :: {:noreply, map()}
  def run(term, brief \\ nil) do
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]
    advisor = advisor(session)

    cond do
      is_nil(advisor) ->
        {:noreply,
         SlashPalette.close(term, "Create a task Participant named Advisor with /agent first")}

      advisor.provider == :unconfigured or is_nil(advisor.model) ->
        {:noreply, SlashPalette.close(term, "Configure the Advisor model with /agents")}

      true ->
        delegate(term, advisor, brief || @default_brief, Map.get(term.assigns, :advisor_delegate))
    end
  end

  @doc "Returns the exact configured Advisor task Participant, if present."
  @spec advisor(map() | nil) :: map() | nil
  def advisor(nil), do: nil

  def advisor(session),
    do:
      Enum.find(
        session.participants,
        &(String.downcase(&1.name || "") == "advisor" and &1.kind == :task)
      )

  defp delegate(term, advisor, brief, nil),
    do: delegate(term, advisor, brief, &Engine.delegate_task/4)

  defp delegate(term, advisor, brief, delegate_fun) do
    case delegate_fun.(
           term.assigns.selected_session_id,
           advisor.id,
           brief,
           term.assigns.engine
         ) do
      {:ok, _turn_id} ->
        {:noreply, Component.assign(SlashPalette.close(term), notice: "Advisor review queued")}

      {:error, reason} ->
        {:noreply, SlashPalette.close(term, "Could not queue Advisor review: #{reason}")}
    end
  end
end
