defmodule ReyCode.Orchestration.Invocation do
  @moduledoc "A durable provider execution in the orchestration projection."

  alias ReyCode.Failure
  alias ReyCode.ProjectInstructions.Capture

  alias ReyCode.Orchestration.{
    InvocationCoordination,
    InvocationExecution,
    Participant,
    ProviderRound,
    Steering,
    ToolAsk,
    ToolRun
  }

  alias ReyCode.Orchestration.Squad.Seat

  @fields [
    :id,
    :room_id,
    :turn_id,
    :message_id,
    :participant,
    :phase_index,
    :phase,
    :cycle,
    :logical_work_id,
    :dependencies,
    :label,
    :system_prompt,
    :project_instructions,
    :execution_context,
    :coordination,
    :status,
    :attempt,
    :usage,
    :tool_events,
    :notes,
    :rounds,
    :pending_steering,
    :tool_runs,
    :tool_run_order,
    :pending_tool_review,
    :completion_metadata,
    :last_frame_sequence,
    :error,
    :delegation_depth,
    :delegated_from_invocation_id,
    :delegated_from_tool_run_id
  ]

  defstruct id: nil,
            room_id: nil,
            turn_id: nil,
            message_id: nil,
            participant: nil,
            phase_index: nil,
            phase: nil,
            cycle: 0,
            logical_work_id: nil,
            dependencies: [],
            label: nil,
            system_prompt: nil,
            project_instructions: nil,
            execution_context: %InvocationExecution{},
            coordination: %InvocationCoordination{},
            status: nil,
            attempt: 1,
            usage: nil,
            tool_events: [],
            notes: [],
            rounds: [],
            pending_steering: [],
            tool_runs: %{},
            tool_run_order: [],
            pending_tool_review: nil,
            completion_metadata: nil,
            last_frame_sequence: 0,
            error: nil,
            delegation_depth: 0,
            delegated_from_invocation_id: nil,
            delegated_from_tool_run_id: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          room_id: String.t() | nil,
          turn_id: String.t() | nil,
          message_id: String.t() | nil,
          participant: Participant.t() | Seat.t() | nil,
          phase_index: non_neg_integer() | nil,
          phase: String.t() | nil,
          cycle: non_neg_integer(),
          logical_work_id: String.t() | nil,
          dependencies: [String.t()],
          label: String.t() | nil,
          system_prompt: String.t() | nil,
          project_instructions: Capture.t() | nil,
          execution_context: InvocationExecution.t(),
          coordination: InvocationCoordination.t(),
          status: atom() | nil,
          attempt: pos_integer(),
          usage: map() | nil,
          tool_events: [map()],
          notes: [String.t()],
          rounds: [ProviderRound.t()],
          tool_runs: %{optional(String.t()) => ToolRun.t()},
          tool_run_order: [String.t()],
          pending_steering: [Steering.t()],
          completion_metadata: map() | nil,
          last_frame_sequence: non_neg_integer(),
          error: Failure.t() | nil,
          delegation_depth: non_neg_integer(),
          delegated_from_invocation_id: String.t() | nil,
          delegated_from_tool_run_id: String.t() | nil
        }

  @doc "Converts a decoded or legacy invocation map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(invocation) when is_map(invocation) do
    capture = instruction_capture(invocation)
    execution_context = execution_context(invocation)
    coordination = coordination(invocation)

    invocation =
      invocation
      |> Map.put(:project_instructions, capture)
      |> Map.put(:execution_context, execution_context)
      |> Map.put(:coordination, coordination)
      |> Map.put_new(:phase_index, Map.get(invocation, :stage))
      |> then(&struct!(__MODULE__, Map.take(&1, @fields)))

    %{
      invocation
      | participant: participant(invocation.participant),
        pending_steering: Enum.map(invocation.pending_steering || [], &Steering.from_map/1),
        rounds: Enum.map(invocation.rounds || [], &ProviderRound.from_map/1),
        tool_runs:
          Map.new(invocation.tool_runs || %{}, fn {id, run} ->
            {id, ToolRun.from_map(run)}
          end),
        pending_tool_review: optional_tool_ask(invocation.pending_tool_review),
        error: optional_failure(invocation.error)
    }
  end

  defp instruction_capture(invocation) do
    case fetch(invocation, :project_instructions) do
      nil ->
        nil

      %Capture{} = capture ->
        capture

      content when is_binary(content) ->
        %Capture{
          content: content,
          digest: fetch(invocation, :project_instruction_digest),
          sources: fetch(invocation, :project_instruction_sources, [])
        }

      capture when is_map(capture) ->
        %Capture{
          content: fetch(capture, :content, ""),
          digest: fetch(capture, :digest),
          sources: fetch(capture, :sources, [])
        }
    end
  end

  defp execution_context(invocation) do
    context =
      case fetch(invocation, :execution_context) do
        nil ->
          %InvocationExecution{
            workspace: fetch(invocation, :workspace),
            workspace_roots: fetch(invocation, :workspace_roots, []),
            output_schema: fetch(invocation, :output_schema),
            isolation: fetch(invocation, :isolation)
          }

        value ->
          InvocationExecution.from_map(value)
      end

    %{
      context
      | model_tier: fetch(invocation, :model_tier, context.model_tier),
        token_budget_tokens: fetch(invocation, :token_budget_tokens, context.token_budget_tokens)
    }
  end

  defp coordination(invocation) do
    case fetch(invocation, :coordination) do
      nil ->
        InvocationCoordination.from_map(%{
          peer_messages: fetch(invocation, :peer_messages, []),
          pending_question: fetch(invocation, :pending_question),
          work_plan: fetch(invocation, :work_plan)
        })

      value ->
        InvocationCoordination.from_map(value)
    end
  end

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp participant(nil), do: nil
  defp participant(%Participant{} = participant), do: participant
  defp participant(%Seat{} = seat), do: seat
  defp participant(%{role_id: _role_id} = seat), do: Seat.from_map(seat)
  defp participant(value), do: Participant.from_map(value)

  defp optional_failure(nil), do: nil
  defp optional_failure(value), do: Failure.from_map(value)

  defp optional_tool_ask(nil), do: nil
  defp optional_tool_ask(review), do: ToolAsk.from_map(review)
end
