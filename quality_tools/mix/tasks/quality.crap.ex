defmodule Mix.Tasks.Quality.Crap do
  @moduledoc """
  Enforces per-function CRAP score limits with a committed baseline ratchet.

      mix quality.crap --lcov cover/lcov.info --baseline quality/crap-baseline.json

  Scores every production function as `CC^2 x (1 - coverage)^3 + CC` from the
  LCOV report. Scores at or below `--max` (default 30) always pass; higher
  scores must not exceed their baseline entry. Use `--write-baseline` to
  regenerate the baseline (offenders only). On pull requests, `--base SHA`
  additionally rejects baseline additions or raised caps relative to the base
  commit so offenders cannot be introduced silently.
  """
  use Mix.Task

  alias ReyCode.Quality.{ChangedCoverage, CrapScore}

  @shortdoc "Enforces per-function CRAP score limits"
  @default_baseline "quality/crap-baseline.json"

  @impl true
  def run(args) do
    {opts, _remaining, invalid} =
      OptionParser.parse(args,
        strict: [
          lcov: :string,
          baseline: :string,
          max: :integer,
          base: :string,
          write_baseline: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    lcov_path = Keyword.get(opts, :lcov, "cover/lcov.info")
    baseline_path = Keyword.get(opts, :baseline, @default_baseline)
    max = Keyword.get(opts, :max, CrapScore.default_max())

    reports = reports(lcov_path)

    if opts[:write_baseline] do
      write_baseline(baseline_path, reports, max)
    else
      baseline = load_baseline!(baseline_path, max)
      enforce_current(reports, baseline, max)
      enforce_ratchet(baseline, opts[:base], baseline_path)
      print_summary(reports, baseline, max)
    end
  end

  defp reports(lcov_path) do
    with {:ok, clauses} <- CrapScore.scan_files(source_files()),
         {:ok, lcov} <- File.read(lcov_path) do
      CrapScore.evaluate(clauses, ChangedCoverage.parse_lcov(lcov))
    else
      {:error, reason} -> Mix.raise("quality.crap failed: #{inspect(reason)}")
    end
  end

  defp source_files do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.sort()
  end

  defp load_baseline!(baseline_path, max) do
    with {:ok, contents} <- File.read(baseline_path),
         {:ok, scores, threshold} <- CrapScore.decode_baseline(contents) do
      unless threshold == max do
        Mix.raise(
          "baseline threshold #{threshold} differs from --max #{max}; regenerate baseline"
        )
      end

      scores
    else
      _error ->
        Mix.raise(
          "missing or invalid baseline at #{baseline_path}; run " <>
            "mix quality.crap --write-baseline and commit the result"
        )
    end
  end

  defp write_baseline(baseline_path, reports, max) do
    File.mkdir_p!(Path.dirname(baseline_path))
    File.write!(baseline_path, CrapScore.encode_baseline(reports, max))

    offenders = Enum.count(reports, &(&1.score > max))

    Mix.shell().info(
      "Wrote baseline #{baseline_path} with #{offenders} offender(s) at max #{max}"
    )
  end

  defp enforce_current(reports, baseline, max) do
    case CrapScore.enforce(reports, baseline, max) do
      {:ok, _reports} ->
        :ok

      {:error, violations} ->
        Mix.raise(violation_message(violations))
    end
  end

  defp enforce_ratchet(_baseline, nil, _baseline_path), do: :ok

  defp enforce_ratchet(baseline, base, baseline_path) do
    case base_baseline(base, baseline_path) do
      :skip ->
        :ok

      {:ok, base_baseline} ->
        case CrapScore.baseline_delta(baseline, base_baseline) do
          :ok ->
            :ok

          {:error, issues} ->
            Mix.raise("""
            Baseline ratchet violation relative to #{base}:
            #{Enum.join(issues, "\n")}
            """)
        end

      {:error, reason} ->
        Mix.raise("could not read baseline from #{base}: #{inspect(reason)}")
    end
  end

  defp base_baseline(base, baseline_path) do
    case System.cmd("git", ["show", "#{base}:#{baseline_path}"], stderr_to_stdout: true) do
      {contents, 0} ->
        case CrapScore.decode_baseline(contents) do
          {:ok, scores, _threshold} -> {:ok, scores}
          {:error, reason} -> {:error, reason}
        end

      {_output, _status} ->
        :skip
    end
  end

  defp violation_message(violations) do
    details = Enum.map_join(violations, "\n", &violation_detail/1)

    """
    CRAP score violations (formula: CC^2 x (1 - coverage)^3 + CC):
    #{details}

    Reduce complexity, add tests, or (for legacy offenders) never worsen the baseline.
    """
  end

  defp violation_detail({:new_offender, report}) do
    "  #{report.id} (#{report.file}:#{report.line}) score #{report.score}, " <>
      "CC #{report.cc}, coverage #{coverage_label(report)} — no baseline entry"
  end

  defp violation_detail({:baseline_regression, report, permitted}) do
    "  #{report.id} (#{report.file}:#{report.line}) score #{report.score} exceeds " <>
      "baseline #{permitted} (CC #{report.cc}, coverage #{coverage_label(report)})"
  end

  defp coverage_label(%{unmeasured: true}), do: "unmeasured"

  defp coverage_label(%{coverage: nil}), do: "0.0%"

  defp coverage_label(%{coverage: coverage}),
    do: "#{Float.round(coverage * 100, 1)}%"

  defp print_summary(reports, baseline, max) do
    offenders = Enum.count(reports, &(&1.score > max))
    unmeasured = Enum.count(reports, & &1.unmeasured)

    Mix.shell().info(
      "CRAP scores: #{length(reports)} functions, #{offenders} baseline offender(s) " <>
        "above #{max}, #{unmeasured} unmeasured by tests"
    )

    Enum.each(CrapScore.stale_entries(reports, baseline), fn id ->
      Mix.shell().info("note: baseline entry #{id} no longer matches code; regenerate baseline")
    end)
  end
end
