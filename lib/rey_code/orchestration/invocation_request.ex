defmodule ReyCode.Orchestration.InvocationRequest do
  @moduledoc "Builds the provider request for one durable invocation round."

  alias ReyCode.Orchestration.Context
  alias ReyCode.Orchestration.{Invocation, ModelTier, Projection, Steering}
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
      system_prompt: system_prompt(invocation),
      messages: Context.messages(room, turn, invocation, projection),
      workspace: invocation.execution_context.workspace || room.workspace,
      resume_from: invocation.last_frame_sequence,
      round_index: length(invocation.rounds),
      attempt: invocation.attempt,
      label: invocation.label,
      phase: invocation.phase,
      cycle: invocation.cycle,
      logical_work_id: invocation.logical_work_id,
      model_tier: invocation.execution_context.model_tier,
      token_budget_tokens: invocation.execution_context.token_budget_tokens,
      used_tokens: ModelTier.used_tokens(invocation),
      agent_delay_ms: request_policy.agent_delay_ms,
      simulator_opts: request_policy.simulator_opts,
      dependencies: invocation.dependencies,
      steering: Enum.map(invocation.pending_steering, &Steering.to_wire/1)
    }
  end

  defp system_prompt(%Invocation{project_instructions: nil} = invocation),
    do: invocation.system_prompt

  defp system_prompt(%Invocation{project_instructions: %{content: ""}} = invocation),
    do: invocation.system_prompt

  defp system_prompt(invocation) do
    [
      invocation.system_prompt,
      "Follow these frozen project instructions for this Invocation:",
      invocation.project_instructions.content
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end
end
