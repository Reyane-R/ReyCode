defmodule ReyCode.Quality.ChangedCoverage do
  @moduledoc """
  Compares an LCOV report with a zero-context Git diff and reports coverage for
  executable Elixir lines added or changed by the branch.
  """

  @type line_hits :: %{optional(pos_integer()) => non_neg_integer()}
  @type coverage :: %{optional(String.t()) => line_hits()}
  @type changed_lines :: %{optional(String.t()) => MapSet.t(pos_integer())}
  @type report :: %{
          covered: non_neg_integer(),
          total: non_neg_integer(),
          percent: float(),
          uncovered: [{String.t(), pos_integer()}]
        }

  @doc "Parses LCOV source and line-hit records into repository-relative paths."
  @spec parse_lcov(String.t(), String.t()) :: coverage()
  def parse_lcov(content, root \\ File.cwd!()) do
    {coverage, _current_file} =
      content
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {coverage, current_file} ->
        cond do
          String.starts_with?(line, "SF:") ->
            file = line |> String.replace_prefix("SF:", "") |> normalize_path(root)
            {Map.put_new(coverage, file, %{}), file}

          String.starts_with?(line, "DA:") and is_binary(current_file) ->
            {put_line_record(coverage, current_file, line), current_file}

          true ->
            {coverage, current_file}
        end
      end)

    coverage
  end

  @doc "Parses changed new-side line numbers from a `git diff --unified=0` result."
  @spec parse_diff(String.t()) :: changed_lines()
  def parse_diff(diff) do
    {changed, _current_file} =
      diff
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {changed, current_file} ->
        cond do
          String.starts_with?(line, "+++ b/") ->
            file = String.replace_prefix(line, "+++ b/", "")
            {Map.put_new(changed, file, MapSet.new()), file}

          line == "+++ /dev/null" ->
            {changed, nil}

          String.starts_with?(line, "@@") and is_binary(current_file) ->
            {Map.update!(changed, current_file, &add_hunk_lines(&1, line)), current_file}

          true ->
            {changed, current_file}
        end
      end)

    changed
  end

  @doc "Calculates coverage for changed executable lines represented in LCOV."
  @spec evaluate(coverage(), changed_lines()) :: report()
  def evaluate(coverage, changed) do
    executable_lines =
      for {file, lines} <- changed,
          line <- lines,
          hits = get_in(coverage, [file, line]),
          is_integer(hits),
          do: {file, line, hits}

    covered = Enum.count(executable_lines, fn {_file, _line, hits} -> hits > 0 end)
    total = length(executable_lines)

    %{
      covered: covered,
      total: total,
      percent: if(total == 0, do: 100.0, else: Float.round(covered / total * 100, 1)),
      uncovered:
        for({file, line, 0} <- executable_lines, do: {file, line})
        |> Enum.sort()
    }
  end

  @doc "Returns `:ok` when changed executable lines meet the requested percentage."
  @spec check(String.t(), String.t(), number(), String.t()) ::
          {:ok, report()} | {:error, report()}
  def check(lcov, diff, threshold, root \\ File.cwd!()) when is_number(threshold) do
    report = evaluate(parse_lcov(lcov, root), parse_diff(diff))

    if report.percent >= threshold, do: {:ok, report}, else: {:error, report}
  end

  defp normalize_path(path, root) do
    path
    |> Path.expand(root)
    |> Path.relative_to(Path.expand(root))
  end

  defp put_line_record(coverage, file, record) do
    fields = record |> String.replace_prefix("DA:", "") |> String.split(",", parts: 3)

    case fields do
      [line_number, hits | _] -> put_parsed_line(coverage, file, line_number, hits)
      _ -> coverage
    end
  end

  defp put_parsed_line(coverage, file, line_number, hits) do
    case {Integer.parse(line_number), Integer.parse(hits)} do
      {{line_number, ""}, {hits, ""}} when line_number > 0 and hits >= 0 ->
        put_in(coverage, [file, line_number], hits)

      _ ->
        coverage
    end
  end

  defp add_hunk_lines(lines, hunk) do
    case Regex.run(~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/, hunk) do
      [_, start, count] -> add_range(lines, String.to_integer(start), String.to_integer(count))
      [_, start] -> add_range(lines, String.to_integer(start), 1)
      _ -> lines
    end
  end

  defp add_range(lines, _start, 0), do: lines

  defp add_range(lines, start, count) do
    Enum.reduce(start..(start + count - 1), lines, &MapSet.put(&2, &1))
  end
end
