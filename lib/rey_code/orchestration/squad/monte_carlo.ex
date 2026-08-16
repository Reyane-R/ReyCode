defmodule ReyCode.Orchestration.Squad.MonteCarlo do
  @moduledoc "Runs many deterministic squad simulations and aggregates outcomes."

  alias ReyCode.Orchestration.Squad.Simulator

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    runs = max(Keyword.get(opts, :runs, 1_000), 1)
    first_seed = Keyword.get(opts, :seed, 0)
    scenario_opts = Keyword.drop(opts, [:runs, :seed])

    0..(runs - 1)
    |> Enum.reduce(initial(runs), fn offset, summary ->
      seed = first_seed + offset
      result = Simulator.run(Keyword.put(scenario_opts, :seed, seed))

      summary
      |> Map.update!(result.outcome, &(&1 + 1))
      |> Map.update!(:max_steps, &max(&1, result.steps))
      |> Map.update!(:max_delay_ms, &max(&1, result.max_delay_ms))
      |> record_failed_seed(seed, result.outcome)
    end)
  end

  defp initial(runs) do
    %{
      runs: runs,
      completed: 0,
      failed: 0,
      max_steps: 0,
      max_delay_ms: 0,
      failed_seeds: []
    }
  end

  defp record_failed_seed(summary, _seed, :completed), do: summary

  defp record_failed_seed(%{failed_seeds: seeds} = summary, seed, :failed) do
    if length(seeds) < 20, do: %{summary | failed_seeds: seeds ++ [seed]}, else: summary
  end
end
