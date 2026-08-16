defmodule ReyCode.Orchestration.Squad.MonteCarloTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Squad.MonteCarlo

  test "runs thousands of deterministic jittered workflows" do
    summary = MonteCarlo.run(runs: 2_000, seed: 100, jitter_ms: 25, failure_rate: 0.05)

    assert summary == %{
             runs: 2_000,
             completed: 1_928,
             failed: 72,
             max_steps: 20,
             max_delay_ms: 25,
             failed_seeds: [
               128,
               131,
               179,
               212,
               227,
               254,
               293,
               396,
               427,
               438,
               532,
               544,
               571,
               576,
               579,
               623,
               628,
               678,
               701,
               719
             ]
           }

    assert summary == MonteCarlo.run(runs: 2_000, seed: 100, jitter_ms: 25, failure_rate: 0.05)
  end
end
