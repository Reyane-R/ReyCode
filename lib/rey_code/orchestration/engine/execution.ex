defmodule ReyCode.Orchestration.Engine.Execution do
  @moduledoc """
  Invocation execution lifecycle for the Engine.

  Owns the runtime decisions around monitored workers — interpreting
  exits, releasing or requeueing admission slots, interrupting started
  runs, and finalizing invocations — plus recovery of durable invocation
  state after restart.

  Exit interpretation is a pure function of the projection and monitor
  map (`plan_worker_exit/3`), so every transition decision is testable
  without a process tree; the Engine applies the planned effect through
  this module.
  """

  alias ReyCode.Failure
  alias ReyCode.Orchestration.Engine.{Admission, DelegationFinalization, Lifecycle}
  alias ReyCode.Orchestration.Engine.WorkerExit

  @type effect :: :ignore | :release | :requeue | {:fail, Failure.t()}

  @type plan ::
          :unmonitored
          | {effect(), String.t() | nil}

  @doc "Recovers durable invocation state after an engine restart."
  def recover(state) do
    state = Lifecycle.recover_invocations(state)

    state.projection.session_order
    |> Enum.reduce(state, fn session_id, acc -> Lifecycle.recover_session(acc, session_id) end)
  end

  @doc """
  Purely plans what a monitored worker's DOWN message means.

  Returns `:unmonitored` for references this engine does not track;
  otherwise the classified effect paired with the invocation ID and the
  post-pop monitor map.
  """
  @spec plan_worker_exit(map(), reference(), term()) ::
          {:unmonitored, map()}
          | {effect(), String.t() | nil, map()}
  def plan_worker_exit(state, ref, reason) do
    case Map.pop(state.agent_monitors, ref) do
      {nil, monitors} ->
        {:unmonitored, monitors}

      {invocation_id, monitors} ->
        invocation = state.projection.invocations[invocation_id]

        {WorkerExit.classify(invocation, reason, &Lifecycle.replayable?/1), invocation_id,
         monitors}
    end
  end

  @doc "Applies a planned exit effect to the engine state."
  def apply_worker_exit(state, ref, reason) do
    case plan_worker_exit(state, ref, reason) do
      {:unmonitored, _monitors} ->
        state

      {effect, invocation_id, monitors} ->
        state = %{state | agent_monitors: monitors}
        invocation = state.projection.invocations[invocation_id]
        apply_effect(state, invocation_id, invocation, effect)
    end
  end

  # A paused approval is durable: release the execution slot without failing
  # so the resolution can resume the loop.
  defp apply_effect(state, invocation_id, _invocation, :release) do
    state
    |> Lifecycle.release_execution(invocation_id)
    |> Lifecycle.pump_admission()
  end

  # The loop stopped for a mid-flight handoff (for example an approval that
  # raced this exit and could not enqueue while the worker still held its
  # slot): re-arm scheduling instead of failing the invocation.
  defp apply_effect(state, invocation_id, _invocation, :requeue) do
    state
    |> Lifecycle.release_execution(invocation_id)
    |> Admission.enqueue(invocation_id)
    |> Lifecycle.pump_admission()
  end

  defp apply_effect(state, _invocation_id, invocation, {:fail, error}) do
    state = Lifecycle.interrupt_started_runs(state, invocation)

    DelegationFinalization.finalize_invocation(state, invocation.id, {:failed, error})
  end

  defp apply_effect(state, _invocation_id, _invocation, :ignore), do: state
end
