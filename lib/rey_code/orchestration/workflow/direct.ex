defmodule ReyCode.Orchestration.Workflow.Direct do
  @moduledoc "Plans one invocation for ordinary conversation or explicit delegation."
  use ReyCode.Orchestration.Workflow

  alias ReyCode.Orchestration.{Delegation, StrategicReview, Workflow, WorkingContract}

  @impl true
  def plan(session, %{strategy_review: packet} = turn, _projection) when not is_nil(packet) do
    participant = participant!(session, turn.participant_id)

    [
      %{
        participant_id: participant.id,
        phase_index: 0,
        label: "strategic review",
        system_prompt: StrategicReview.prompt(packet)
      }
    ]
  end

  def plan(session, turn, _projection) do
    participant = participant!(session, turn.participant_id)
    delegated? = not is_nil(turn.participant_id)
    detached? = Map.get(turn, :detached?, false)

    [
      %{
        participant_id: participant.id,
        phase_index: 0,
        label:
          if(detached?,
            do: "detached task",
            else: if(delegated?, do: "delegated task", else: "assistant response")
          ),
        system_prompt:
          system_prompt(session, participant, delegated?, detached?, Map.get(turn, :task))
      }
    ]
  end

  @impl true
  def advance(session, turn, projection), do: Workflow.advance_parallel(session, turn, projection)

  defp participant!(session, nil) do
    Enum.find(session.participants, &(&1.kind == :primary)) ||
      raise "session #{session.id} has no primary participant"
  end

  defp participant!(session, participant_id) do
    Enum.find(session.participants, &(&1.id == participant_id)) ||
      raise "session #{session.id} has no participant #{participant_id}"
  end

  # A verified-change Session restricts tools to the change boundary, which
  # excludes delegation, so its prompt must not advertise task agents.
  defp system_prompt(session, participant, false, false, _task) do
    identity =
      "You are #{participant.name}, the session's primary coding assistant. " <>
        "Responsibility: #{participant.perspective}."

    if is_nil(session.verified_change),
      do: WorkingContract.append(identity <> "\n\n" <> Delegation.primary_guidance(session)),
      else: WorkingContract.append(identity)
  end

  defp system_prompt(_session, participant, true, false, _task) do
    ("You are the #{participant.name} task agent. " <>
       "Standing responsibility: #{participant.perspective}. Complete only the delegated task.")
    |> WorkingContract.append()
  end

  defp system_prompt(_session, participant, true, true, task) do
    ("You are the #{participant.name} task agent. " <>
       "Standing responsibility: #{participant.perspective}. " <>
       "Complete the detached task and report the result.\n\nDetached task:\n#{task}")
    |> WorkingContract.append()
  end
end
