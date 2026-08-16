defmodule ReyCode.Orchestration.Workflow.FanOut do
  @moduledoc false
  use ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.Workflow

  @impl true
  def plan(room, _turn, _projection) do
    Enum.map(room.participants, fn participant ->
      %{
        participant_id: participant.id,
        stage: 0,
        label: "parallel branch",
        system_prompt:
          "Take ownership of an independent approach from the perspective of #{participant.perspective}. Produce a self-contained result that can be compared or combined later."
      }
    end)
  end

  @impl true
  def advance(room, turn, projection), do: Workflow.advance_parallel(room, turn, projection)
end
