defmodule ReyCode.Orchestration.Invocation do
  @moduledoc "A durable provider execution in the orchestration projection."

  alias ReyCode.Failure
  alias ReyCode.Orchestration.{Participant, ProviderRound, ToolRun}
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
            phase_index: nil,
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
          participant: Participant.t() | Seat.t() | nil,
          phase_index: non_neg_integer() | nil,
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
          rounds: [ProviderRound.t()],
          tool_runs: %{optional(String.t()) => ToolRun.t()},
          tool_run_order: [String.t()],
          pending_tool_review: map() | nil,
          completion_metadata: map() | nil,
          last_frame_sequence: non_neg_integer(),
          error: Failure.t() | nil
        }

  @doc "Converts a decoded or legacy invocation map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(invocation) when is_map(invocation) do
    invocation =
      invocation
      |> Map.put_new(:phase_index, Map.get(invocation, :stage))
      |> then(&struct!(__MODULE__, Map.take(&1, @fields)))

    %{
      invocation
      | participant: participant(invocation.participant),
        rounds: Enum.map(invocation.rounds || [], &ProviderRound.from_map/1),
        tool_runs:
          Map.new(invocation.tool_runs || %{}, fn {id, run} ->
            {id, ToolRun.from_map(run)}
          end),
        error: optional_failure(invocation.error)
    }
  end

  defp participant(nil), do: nil
  defp participant(%Participant{} = participant), do: participant
  defp participant(%Seat{} = seat), do: seat
  defp participant(%{role_id: _role_id} = seat), do: Seat.from_map(seat)
  defp participant(value), do: Participant.from_map(value)

  defp optional_failure(nil), do: nil
  defp optional_failure(value), do: Failure.from_map(value)
end
