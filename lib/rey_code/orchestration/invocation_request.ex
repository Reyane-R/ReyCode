defmodule ReyCode.Orchestration.InvocationRequest do
  @moduledoc "Builds the provider request for one durable invocation round."

  alias ReyCode.Orchestration.Context
  alias ReyCode.Orchestration.{Invocation, Projection}
  alias ReyCode.Provider.Request

  @type request_policy :: %{
          required(:agent_delay_ms) => non_neg_integer() | nil,
          required(:simulator_opts) => keyword() | nil
        }

  @spec build(Invocation.t(), Projection.t(), request_policy()) :: Request.t()
  def build(invocation, projection, request_policy) do
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
      round_index: length(invocation.rounds),
      attempt: invocation.attempt,
      label: invocation.label,
      phase: invocation.phase,
      cycle: invocation.cycle,
      logical_work_id: invocation.logical_work_id,
      agent_delay_ms: request_policy.agent_delay_ms,
      simulator_opts: request_policy.simulator_opts,
      dependencies: invocation.dependencies
    }
  end
end
