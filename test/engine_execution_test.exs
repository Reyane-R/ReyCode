defmodule ReyCode.Orchestration.Engine.ExecutionTest do
  use ExUnit.Case, async: true

  alias ReyCode.Failure
  alias ReyCode.Orchestration.Engine.Execution
  alias ReyCode.Orchestration.{Invocation, Projection}

  # Exit planning is pure over the projection and the monitor map, so every
  # transition decision is exercised here without a GenServer, Registry,
  # EventStore, or DynamicSupervisor.
  defp state_with(monitors, invocations) do
    %{agent_monitors: monitors, projection: %Projection{invocations: invocations}}
  end

  defp invocation(status \\ :running) do
    %Invocation{
      id: "inv-1",
      status: status,
      participant: %{id: "primary", provider: :simulator}
    }
  end

  test "an unmonitored reference plans no effect" do
    state = state_with(%{}, %{"inv-1" => invocation()})

    assert {:unmonitored, %{}} = Execution.plan_worker_exit(state, make_ref(), :normal)
  end

  test "a normal exit requeues the invocation" do
    ref = make_ref()
    state = state_with(%{ref => "inv-1"}, %{"inv-1" => invocation()})

    assert {:requeue, "inv-1", %{}} = Execution.plan_worker_exit(state, ref, :normal)
  end

  test "waiting tool approval releases the slot durably" do
    ref = make_ref()
    state = state_with(%{ref => "inv-1"}, %{"inv-1" => invocation(:waiting_tool_approval)})

    assert {:release, "inv-1", %{}} = Execution.plan_worker_exit(state, ref, :killed)
  end

  test "a crashed running worker plans a durable failure with replayability" do
    ref = make_ref()
    state = state_with(%{ref => "inv-1"}, %{"inv-1" => invocation()})

    {:fail, failure} = elem(Execution.plan_worker_exit(state, ref, :killed), 0)

    assert %Failure{category: :worker_exit, retryable?: true} = failure
  end

  test "non-replayable providers fail without retry eligibility" do
    ref = make_ref()
    provider = %{id: "primary", provider: :opencode}
    invocation = %{invocation() | participant: provider}
    state = state_with(%{ref => "inv-1"}, %{"inv-1" => invocation})

    {{:fail, failure}, "inv-1", %{}} = Execution.plan_worker_exit(state, ref, :killed)

    refute failure.retryable?
  end

  test "terminal invocations ignore their workers' late exits" do
    ref = make_ref()
    state = state_with(%{ref => "inv-1"}, %{"inv-1" => invocation(:completed)})

    assert {:ignore, "inv-1", _monitors} = Execution.plan_worker_exit(state, ref, :late)
  end

  test "apply_worker_exit leaves state untouched for unmonitored references" do
    state = state_with(%{}, %{"inv-1" => invocation()})

    assert ^state = Execution.apply_worker_exit(state, make_ref(), :normal)
  end
end
