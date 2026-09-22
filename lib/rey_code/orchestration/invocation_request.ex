defmodule ReyCode.Orchestration.InvocationRequest do
  @moduledoc "Builds the provider request for one durable invocation round."

  alias ReyCode.Orchestration.Context

  alias ReyCode.Orchestration.{
    Invocation,
    Projection,
    Steering,
    StrategicReview,
    VerifiedChangeContext
  }

  alias ReyCode.Provider.Request
  alias ReyCode.Security.VerifiedChangeBoundary

  @type request_policy :: %{
          required(:agent_delay_ms) => non_neg_integer() | nil,
          required(:simulator_opts) => keyword() | nil
        }

  @spec build(Invocation.t(), Projection.t(), request_policy()) :: Request.t()
  def build(invocation, projection, request_policy) do
    turn = projection.turns[invocation.turn_id]
    session = projection.sessions[invocation.session_id]

    %Request{
      invocation_id: invocation.id,
      turn_id: turn.id,
      session_id: session.id,
      mode: turn.mode,
      participant: invocation.participant,
      system_prompt_mode: if(turn.strategy_review, do: :frozen, else: :augmented),
      system_prompt:
        if(turn.strategy_review,
          do: StrategicReview.prompt(turn.strategy_review),
          else: system_prompt(invocation, session.verified_change)
        ),
      messages: Context.messages(session, turn, invocation, projection),
      tool_names:
        if(turn.strategy_review, do: [], else: VerifiedChangeBoundary.tool_names(session)),
      workspace:
        if(session.verified_change,
          do: session.verified_change.workspace,
          else: invocation.execution_context.workspace || session.workspace
        ),
      resume_from: invocation.last_frame_sequence,
      round_index: length(invocation.rounds),
      attempt: invocation.attempt,
      label: invocation.label,
      phase: invocation.phase,
      cycle: invocation.cycle,
      logical_work_id: invocation.logical_work_id,
      model_tier: invocation.execution_context.model_tier,
      provider_retry_failure: provider_retry_failure(invocation),
      session_context_summary_bytes: optional_byte_size(session.context_summary),
      agent_delay_ms: request_policy.agent_delay_ms,
      simulator_opts: request_policy.simulator_opts,
      dependencies: invocation.dependencies,
      steering: Enum.map(invocation.pending_steering, &Steering.to_wire/1)
    }
  end

  defp provider_retry_failure(%{provider_round_attempt: %{state: :retry_scheduled} = attempt}),
    do: attempt.last_failure

  defp provider_retry_failure(_invocation), do: nil

  defp optional_byte_size(nil), do: nil
  defp optional_byte_size(value), do: byte_size(value)

  defp system_prompt(invocation, nil), do: system_prompt(invocation)

  defp system_prompt(invocation, record) do
    [system_prompt(invocation), VerifiedChangeContext.prompt(record)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
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
