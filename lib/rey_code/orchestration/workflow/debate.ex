defmodule ReyCode.Orchestration.Workflow.Debate do
  @moduledoc false
  use ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.Workflow

  @impl true
  def plan(room, _turn, _projection) do
    [proposal_spec(lead(room))]
  end

  @impl true
  def advance(room, turn, projection) do
    invocations = Workflow.invocations(turn, projection)
    proposal = Enum.filter(invocations, &(&1.phase_index == 0))

    if proposal == [] or not Enum.all?(proposal, &Workflow.terminal?/1) do
      :wait
    else
      advance_after_proposal(room, invocations)
    end
  end

  defp advance_after_proposal(room, invocations) do
    critiques = Enum.filter(invocations, &(&1.phase_index == 1))
    revision = Enum.filter(invocations, &(&1.phase_index == 2))

    cond do
      critiques == [] and revision == [] ->
        continue_with_critiques(room)

      critiques != [] and not Enum.all?(critiques, &Workflow.terminal?/1) ->
        :wait

      revision == [] ->
        {:continue, [revision_spec(lead(room))]}

      Enum.all?(revision, &Workflow.terminal?/1) ->
        {:complete, Workflow.outcome(invocations)}

      true ->
        :wait
    end
  end

  defp continue_with_critiques(room) do
    critics = Enum.reject(room.participants, &(&1.id == lead(room).id))

    if critics == [] do
      {:continue, [revision_spec(lead(room))]}
    else
      {:continue, Enum.map(critics, &critique_spec/1)}
    end
  end

  defp lead(room), do: hd(room.participants)

  defp proposal_spec(participant) do
    %{
      participant_id: participant.id,
      phase_index: 0,
      label: "proposal",
      system_prompt: "Act as the debate lead. Offer a concrete proposal with explicit tradeoffs."
    }
  end

  defp critique_spec(participant) do
    %{
      participant_id: participant.id,
      phase_index: 1,
      label: "critique",
      system_prompt:
        "Review the lead proposal from the perspective of #{participant.perspective}. Identify the strongest flaw and suggest a correction."
    }
  end

  defp revision_spec(participant) do
    %{
      participant_id: participant.id,
      phase_index: 2,
      label: "revision",
      system_prompt:
        "Revise the proposal after considering the critiques. State what changed and provide the final recommendation."
    }
  end
end
