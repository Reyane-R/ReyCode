defmodule ReyCode.Orchestration.Workflow do
  @moduledoc "Scheduling contract for room turn strategies."

  alias ReyCode.Orchestration.{EventEntries, Invocation, Message, Projection, Room, Turn}

  @type spec :: %{
          participant_id: String.t(),
          phase_index: non_neg_integer(),
          label: String.t(),
          system_prompt: String.t()
        }

  @type invocation_outcome :: {:completed, map()} | {:failed, map()}
  @type finalization ::
          {:advance, [EventEntries.event_entry()]}
          | {:retry, [EventEntries.event_entry()], spec()}

  @callback plan(Room.t(), Turn.t(), Projection.t()) :: [spec()]
  @callback advance(Room.t(), Turn.t(), Projection.t()) ::
              :wait | {:continue, [spec()]} | {:complete, atom()}
  @callback finalize(Invocation.t(), Message.t(), invocation_outcome(), keyword()) ::
              finalization()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl true
      def finalize(invocation, _message, outcome, _opts),
        do: unquote(__MODULE__).finalize_invocation(invocation, outcome)
    end
  end

  def invocations(turn, projection) do
    Enum.map(turn.invocation_order, &projection.invocations[&1])
  end

  def advance_parallel(_room, turn, projection) do
    invocations = invocations(turn, projection)

    if invocations != [] and Enum.all?(invocations, &terminal?/1) do
      {:complete, outcome(invocations)}
    else
      :wait
    end
  end

  def terminal?(invocation), do: invocation.status in [:completed, :failed]

  def outcome(invocations) do
    completed = Enum.count(invocations, &(&1.status == :completed))

    cond do
      completed == length(invocations) -> :completed
      completed > 0 -> :partial
      true -> :failed
    end
  end

  @doc "Builds the default terminal action for a completed or failed invocation."
  @spec finalize_invocation(Invocation.t(), invocation_outcome()) :: finalization()
  def finalize_invocation(invocation, outcome) do
    {:advance, [EventEntries.invocation_terminal(invocation, outcome)]}
  end
end
