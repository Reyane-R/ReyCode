defmodule ReyCode.Orchestration.InvocationCoordination do
  @moduledoc "Durable human, peer, and WorkPlan coordination state for one Invocation."

  alias ReyCode.Orchestration.{OperatorQuestion, PeerMessage, WorkPlan}

  @fields [:peer_messages, :pending_question, :work_plan]
  defstruct peer_messages: [], pending_question: nil, work_plan: nil

  @type t :: %__MODULE__{
          peer_messages: [PeerMessage.t()],
          pending_question: OperatorQuestion.t() | nil,
          work_plan: WorkPlan.t() | nil
        }

  @doc "Converts a decoded or legacy coordination map into typed records."
  @spec from_map(t() | map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = coordination), do: coordination

  def from_map(coordination) when is_map(coordination) do
    coordination = struct!(__MODULE__, Map.take(coordination, @fields))

    %{
      coordination
      | peer_messages: Enum.map(coordination.peer_messages || [], &PeerMessage.from_map/1),
        pending_question: optional_question(coordination.pending_question),
        work_plan: WorkPlan.from_map(coordination.work_plan)
    }
  end

  defp optional_question(nil), do: nil
  defp optional_question(question), do: OperatorQuestion.from_map(question)
end
