defmodule ReyCode.Orchestration.Workflow.Eval do
  @moduledoc "Model-audition workflow: independent parallel invocations for task Participants only."

  use ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.Workflow

  @impl true
  def plan(session, _turn, _projection) do
    session.participants
    |> Enum.filter(&(&1.kind == :task))
    |> Enum.map(fn participant ->
      %{
        participant_id: participant.id,
        phase_index: 0,
        label: "model audition",
        system_prompt:
          "Respond independently from the perspective of #{participant.perspective}. " <>
            "Do not assume you can see other agents' current answers."
      }
    end)
  end

  @impl true
  def advance(session, turn, projection), do: Workflow.advance_parallel(session, turn, projection)
end
