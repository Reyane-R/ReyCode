defmodule ReyCode.Orchestration.Workflow do
  @moduledoc "Scheduling contract for session turn strategies."

  alias ReyCode.Failure
  alias ReyCode.Orchestration.{EventEntries, Invocation, Message, Projection, Session, Turn}

  @type spec :: %{
          participant_id: String.t(),
          phase_index: non_neg_integer(),
          label: String.t(),
          system_prompt: String.t()
        }

  # Completed metadata is provider wire data; failed outcomes are typed
  # internal failures converted to wire only at the event boundary.
  @type invocation_outcome :: {:completed, map()} | {:failed, Failure.t()}
  @type finalization ::
          {:advance, [EventEntries.event_entry()]}
          | {:retry, [EventEntries.event_entry()], spec()}

  @callback plan(Session.t(), Turn.t(), Projection.t()) :: [spec()]
  @callback advance(Session.t(), Turn.t(), Projection.t()) ::
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

  def advance_parallel(_session, turn, projection) do
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
