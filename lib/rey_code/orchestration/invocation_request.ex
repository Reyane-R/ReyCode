defmodule ReyCode.Orchestration.InvocationRequest do
  @moduledoc "Builds the provider request for one durable invocation round."

  alias ReyCode.Orchestration.Context
  alias ReyCode.Provider.Request

  @spec build(map(), map(), non_neg_integer() | nil) :: Request.t()
  def build(invocation, projection, agent_delay_ms) do
    turn = projection.turns[invocation.turn_id]
    room = projection.rooms[invocation.room_id]

    %Request{
      invocation_id: invocation.id,
      turn_id: turn.id,
      room_id: room.id,
      mode: turn.mode,
      participant: invocation.participant,
      system_prompt: invocation.system_prompt,
      messages: Context.messages(room, turn, invocation, projection),
      workspace: room.workspace,
      resume_from: invocation.last_frame_sequence,
      round_index: length(Map.get(invocation, :rounds, [])),
      attempt: invocation.attempt,
      label: invocation.label,
      phase: invocation.phase,
      cycle: invocation.cycle,
      logical_work_id: invocation.logical_work_id,
      agent_delay_ms: agent_delay_ms,
      dependencies: invocation.dependencies
    }
  end
end
