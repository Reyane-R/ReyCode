defmodule ReyCode.Orchestration.Workflow.Direct do
  @moduledoc "Plans one invocation for ordinary conversation or explicit delegation."
  use ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.Workflow

  @impl true
  def plan(room, turn, _projection) do
    participant = participant!(room, turn.participant_id)
    delegated? = not is_nil(turn.participant_id)

    [
      %{
        participant_id: participant.id,
        phase_index: 0,
        label: if(delegated?, do: "delegated task", else: "assistant response"),
        system_prompt: system_prompt(participant, delegated?)
      }
    ]
  end

  @impl true
  def advance(room, turn, projection), do: Workflow.advance_parallel(room, turn, projection)

  defp participant!(room, nil) do
    Enum.find(room.participants, &(&1.kind == :primary)) ||
      raise "room #{room.id} has no primary participant"
  end

  defp participant!(room, participant_id) do
    Enum.find(room.participants, &(&1.id == participant_id)) ||
      raise "room #{room.id} has no participant #{participant_id}"
  end

  defp system_prompt(participant, false) do
    "You are #{participant.name}, the room's primary coding assistant. " <>
      "Responsibility: #{participant.perspective}."
  end

  defp system_prompt(participant, true) do
    "You are the #{participant.name} task agent. " <>
      "Standing responsibility: #{participant.perspective}. Complete only the delegated task."
  end
end
