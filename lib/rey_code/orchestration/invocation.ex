defmodule ReyCode.Orchestration.Invocation do
  @moduledoc "A durable provider invocation in the orchestration projection."

  alias ReyCode.Orchestration.{Participant, ToolRun}

  @fields [
    :id,
    :room_id,
    :turn_id,
    :message_id,
    :participant,
    :stage,
    :phase,
    :cycle,
    :logical_work_id,
    :dependencies,
    :label,
    :system_prompt,
    :status,
    :attempt,
    :usage,
    :tool_events,
    :rounds,
    :tool_runs,
    :tool_run_order,
    :pending_tool_review,
    :completion_metadata,
    :last_frame_sequence,
    :error
  ]

  defstruct id: nil,
            room_id: nil,
            turn_id: nil,
            message_id: nil,
            participant: nil,
            stage: nil,
            phase: nil,
            cycle: 0,
            logical_work_id: nil,
            dependencies: [],
            label: nil,
            system_prompt: nil,
            status: nil,
            attempt: 1,
            usage: nil,
            tool_events: [],
            rounds: [],
            tool_runs: %{},
            tool_run_order: [],
            pending_tool_review: nil,
            completion_metadata: nil,
            last_frame_sequence: 0,
            error: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          room_id: String.t() | nil,
          turn_id: String.t() | nil,
          message_id: String.t() | nil,
          participant: Participant.t() | nil,
          stage: non_neg_integer() | nil,
          phase: String.t() | nil,
          cycle: non_neg_integer(),
          logical_work_id: String.t() | nil,
          dependencies: [String.t()],
          label: String.t() | nil,
          system_prompt: String.t() | nil,
          status: atom() | nil,
          attempt: pos_integer(),
          usage: map() | nil,
          tool_events: [map()],
          rounds: [map()],
          tool_runs: %{optional(String.t()) => ToolRun.t()},
          tool_run_order: [String.t()],
          pending_tool_review: map() | nil,
          completion_metadata: map() | nil,
          last_frame_sequence: non_neg_integer(),
          error: map() | nil
        }

  @doc "Converts a decoded or legacy invocation map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(invocation) when is_map(invocation) do
    invocation = struct!(__MODULE__, Map.take(invocation, @fields))

    %{
      invocation
      | participant: participant(invocation.participant),
        tool_runs:
          Map.new(invocation.tool_runs || %{}, fn {id, run} ->
            {id, ToolRun.from_map(run)}
          end)
    }
  end

  defp participant(nil), do: nil
  defp participant(value), do: Participant.from_map(value)
end
