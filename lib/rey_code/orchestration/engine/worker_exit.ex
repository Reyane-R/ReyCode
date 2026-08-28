defmodule ReyCode.Orchestration.Engine.WorkerExit do
  @moduledoc "Classifies a monitored provider worker exit as an orchestration action."

  alias ReyCode.Failure
  alias ReyCode.Orchestration.{Invocation, ToolRuns}

  @terminal [:completed, :failed, :cancelled]

  @type action :: :ignore | :release | :requeue | {:fail, Failure.t()}

  @spec classify(Invocation.t() | nil, term(), (term() -> boolean())) :: action()
  def classify(nil, _reason, _replayable?), do: :ignore

  def classify(%{status: status}, _reason, _replayable?) when status in @terminal,
    do: :ignore

  def classify(invocation, _reason, _replayable?)
      when invocation.status in [:waiting_tool_approval, :waiting_operator, :awaiting_delegation],
      do: :release

  def classify(invocation, reason, replayable?) do
    cond do
      ToolRuns.awaiting?(invocation) ->
        :release

      reason == :normal ->
        :requeue

      true ->
        {:fail,
         Failure.new(
           :worker_exit,
           "Provider worker exited before recording a result: #{inspect(reason)}",
           replayable?.(invocation.participant.provider)
         )}
    end
  end
end
