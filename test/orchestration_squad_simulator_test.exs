defmodule ReyCode.Orchestration.Squad.SimulatorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Orchestration.Squad.Simulator
  alias ReyCode.Provider.Simulator.Scenario

  test "runs the full workflow without processes or sleeping" do
    result = Simulator.run(seed: 42, delay_ms: 10, jitter_ms: 5)

    assert result.outcome == :completed
    assert result.steps == 16
    assert result.max_delay_ms == 14
    assert length(result.artifacts) == 14
  end

  test "drives a targeted release rework through integration" do
    result = Simulator.run(seed: 42, leader_rework_rounds: 1)

    assert result.outcome == :completed
    assert result.state.rework_count == 1
    assert Enum.count(result.events, &(&1.phase == "integration")) == 2
  end

  test "permanent failures terminate deterministically" do
    scenario =
      Scenario.new(
        seed: 7,
        failure_plan: %{{"stories", "analyst", 1} => :permanent}
      )

    assert Simulator.run(scenario).outcome == :failed
    assert Simulator.run(scenario) == Simulator.run(scenario)
  end

  test "retryable failures stop at the shared attempt limit" do
    scenario =
      Scenario.new(
        seed: 8,
        failure_plan: %{
          {"stories", "analyst", 1} => :retryable,
          {"stories", "analyst", 2} => :retryable
        }
      )

    result = Simulator.run(scenario)

    assert result.outcome == :failed
    assert Enum.map(result.failures, & &1.attempt) == [1, 2]
  end

  test "retries simulator worker crashes using the shared classification" do
    scenario =
      Scenario.new(
        seed: 9,
        failure_plan: %{{"stories", "analyst", 1} => :crash}
      )

    result = Simulator.run(scenario)

    assert result.outcome == :completed
    assert [%{attempt: 1, kind: :crash}] = result.failures
  end

  property "monte carlo runs always terminate inside the step bound" do
    check all(
            seed <- integer(1..10_000),
            failure_rate <- float(min: 0.0, max: 0.2),
            max_runs: 300
          ) do
      result = Simulator.run(seed: seed, failure_rate: failure_rate, jitter_ms: 50)

      assert result.outcome in [:completed, :failed]
      assert result.steps <= 90
      assert result.max_delay_ms <= 50
    end
  end
end
