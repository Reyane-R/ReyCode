defmodule ReyCode.Orchestration.Workflow.Compare do
  @moduledoc false
  use ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.Workflow

  @impl true
  def plan(session, _turn, _projection) do
    Enum.map(session.participants, fn participant ->
      %{
        participant_id: participant.id,
        phase_index: 0,
        label: "independent response",
        system_prompt:
          "Respond independently from the perspective of #{participant.perspective}. Do not assume you can see other agents' current answers."
      }
    end)
  end

  @impl true
  def advance(session, turn, projection), do: Workflow.advance_parallel(session, turn, projection)
end
