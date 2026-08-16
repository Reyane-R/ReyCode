defmodule Mix.Tasks.Quality.ChangedCoverage do
  @moduledoc "Enforces an LCOV threshold on executable Elixir lines changed from a Git base."
  use Mix.Task

  alias ReyCode.Quality.ChangedCoverage

  @shortdoc "Checks coverage of changed executable lines"
  @source_pathspecs [":(glob)lib/**/*.ex"]

  @doc false
  def source_pathspecs, do: @source_pathspecs

  @impl true
  def run(args) do
    {opts, _remaining, invalid} =
      OptionParser.parse(args,
        strict: [base: :string, lcov: :string, threshold: :integer]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    base = Keyword.get(opts, :base) || Mix.raise("--base is required")
    lcov_path = Keyword.get(opts, :lcov, "cover/lcov.info")
    threshold = Keyword.get(opts, :threshold, 90)

    {diff, status} =
      System.cmd(
        "git",
        ["diff", "--unified=0", base, "--"] ++ source_pathspecs(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("git diff failed: #{diff}")

    lcov = File.read!(lcov_path)

    case ChangedCoverage.check(lcov, diff, threshold) do
      {:ok, report} ->
        Mix.shell().info(
          "Changed-line coverage: #{report.percent}% (#{report.covered}/#{report.total})"
        )

      {:error, report} ->
        details =
          Enum.map_join(report.uncovered, "\n", fn {file, line} -> "  #{file}:#{line}" end)

        Mix.raise("""
        Changed-line coverage is #{report.percent}% (#{report.covered}/#{report.total}); required #{threshold}%.
        Uncovered changed executable lines:
        #{details}
        """)
    end
  end
end
