defmodule ReyCode.Quality.CrapScore do
  @moduledoc """
  Computes per-function CRAP scores from cyclomatic complexity and LCOV coverage.

  The formula is the classic change-risk predictor (Bob Martin):

      CRAP = CC^2 x (1 - coverage)^3 + CC

  where `CC` is the cyclomatic complexity of the function (Credo's calculator)
  and `coverage` is the fraction of the function's executable lines exercised
  by tests. Functions with no measured lines are treated as uncovered and
  flagged `unmeasured`.

  Multi-clause functions are merged into one score: `1 + sum(CC_i - 1)`, the
  cyclomatic number of the union of clause bodies.

  Enforcement is a baseline ratchet: scores at or below `max` always pass;
  scores above `max` must not exceed their committed baseline entry, and no
  new baseline entries are allowed.
  """

  alias Credo.Check.Refactor.CyclomaticComplexity
  alias ReyCode.Quality.ChangedCoverage

  @default_max 30

  @def_ops [:def, :defp, :defmacro]

  @type clause :: %{
          required(:id) => String.t(),
          required(:module) => String.t(),
          required(:name) => atom(),
          required(:arity) => non_neg_integer(),
          required(:file) => String.t(),
          required(:line) => pos_integer(),
          required(:end_line) => pos_integer(),
          required(:cc) => pos_integer()
        }

  @type report :: %{
          required(:id) => String.t(),
          required(:file) => String.t(),
          required(:line) => pos_integer(),
          required(:cc) => pos_integer(),
          required(:clauses) => pos_integer(),
          required(:covered) => non_neg_integer(),
          required(:total) => non_neg_integer(),
          required(:coverage) => float() | nil,
          required(:unmeasured) => boolean(),
          required(:score) => float()
        }

  @type violation ::
          {:new_offender, report()}
          | {:baseline_regression, report(), number()}

  @doc "The conventional CRAP failure threshold."
  @spec default_max :: pos_integer()
  def default_max, do: @default_max

  @doc "Collects def clauses from every file, failing on the first unreadable or unparsable source."
  @spec scan_files([String.t()]) :: {:ok, [clause()]} | {:error, term()}
  def scan_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case read_clauses(file) do
        {:ok, clauses} -> {:cont, {:ok, acc ++ clauses}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read_clauses(file) do
    case File.read(file) do
      {:ok, source} -> collect(source, file)
      {:error, reason} -> {:error, {:unreadable_file, file, reason}}
    end
  end

  @doc "Parses one Elixir source into its def clauses."
  @spec collect(String.t(), String.t()) :: {:ok, [clause()]} | {:error, term()}
  def collect(source, file) do
    ast = Code.string_to_quoted!(source)
    {:ok, Enum.reverse(traverse(ast, [], [], file))}
  rescue
    _error -> {:error, {:invalid_source, file}}
  end

  @doc "Merges clauses into per-function reports with coverage and CRAP scores, sorted by function ID."
  @spec evaluate([clause()], ChangedCoverage.coverage()) :: [report()]
  def evaluate(clauses, coverage) do
    clauses
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, group} -> report_for(group, coverage) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Enforces the ratchet against a baseline of permitted scores.

  Passes when every report scores at or below `max`, or within its baseline
  entry. Fails with violations for new offenders and baseline regressions.
  """
  @spec enforce([report()], %{optional(String.t()) => number()}, number()) ::
          {:ok, [report()]} | {:error, [violation()]}
  def enforce(reports, baseline, max \\ @default_max) do
    violations =
      Enum.flat_map(reports, fn report ->
        if report.score <= max, do: [], else: violation_for(report, Map.get(baseline, report.id))
      end)

    if violations == [], do: {:ok, reports}, else: {:error, violations}
  end

  @doc "Baseline entries whose function no longer exists in the scanned code."
  @spec stale_entries([report()], map()) :: [String.t()]
  def stale_entries(reports, baseline) do
    ids = MapSet.new(reports, & &1.id)

    for id <- Map.keys(baseline), not MapSet.member?(ids, id), do: id
  end

  @doc """
  Compares a baseline with its version from the base commit.

  Ratchet rules: entries may be removed or reduced; additions and raised caps
  are rejected so offenders cannot be introduced silently.
  """
  @spec baseline_delta(map(), map()) :: :ok | {:error, [String.t()]}
  def baseline_delta(current, base) do
    issues =
      Enum.flat_map(current, fn {id, permitted} ->
        cond do
          not Map.has_key?(base, id) ->
            ["baseline entry added for #{id} (#{permitted}); refactor or add tests instead"]

          permitted > base[id] ->
            ["baseline cap raised for #{id}: #{base[id]} -> #{permitted}"]

          true ->
            []
        end
      end)

    if issues == [], do: :ok, else: {:error, Enum.sort(issues)}
  end

  @doc "Encodes the current offender set (scores above `max`) as a deterministic baseline document."
  @spec encode_baseline([report()], number()) :: String.t()
  def encode_baseline(reports, max \\ @default_max) do
    functions =
      reports
      |> Enum.filter(&(&1.score > max))
      |> Map.new(&{&1.id, &1.score})

    Jason.encode!(%{"threshold" => max, "functions" => functions}, pretty: true) <> "\n"
  end

  @doc "Decodes a baseline document into its scores and threshold."
  @spec decode_baseline(String.t()) :: {:ok, map(), number()} | {:error, :invalid_baseline}
  def decode_baseline(contents) do
    with {:ok, %{"functions" => functions} = document} <- Jason.decode(contents),
         true <- is_map(functions),
         true <- valid_scores?(functions) do
      {:ok, functions, document["threshold"] || @default_max}
    else
      _other -> {:error, :invalid_baseline}
    end
  end

  defp valid_scores?(functions) do
    Enum.all?(functions, fn {id, score} -> is_binary(id) and is_number(score) end)
  end

  defp report_for(group, coverage) do
    first = hd(group)
    spans = Enum.map(group, &{&1.line, &1.end_line})
    hits = hits_in_spans(Map.get(coverage, first.file, %{}), spans)

    total = length(hits)
    covered = Enum.count(hits, &(&1 > 0))
    cc = merge_cc(group)
    coverage_value = if total > 0, do: covered / total, else: nil

    %{
      id: first.id,
      file: first.file,
      line: Enum.min(Enum.map(group, & &1.line)),
      cc: cc,
      clauses: length(group),
      covered: covered,
      total: total,
      coverage: coverage_value && Float.round(coverage_value, 3),
      unmeasured: total == 0,
      score: Float.round(score(cc, coverage_value), 1)
    }
  end

  defp hits_in_spans(file_coverage, spans) do
    for {line, count} <- file_coverage, line_in_spans?(line, spans), do: count
  end

  defp line_in_spans?(line, spans) do
    Enum.any?(spans, fn {start_line, end_line} -> line >= start_line and line <= end_line end)
  end

  defp merge_cc(group) do
    group |> Enum.map(& &1.cc) |> Enum.sum() |> Kernel.-(length(group) - 1)
  end

  defp score(cc, nil), do: cc * cc * 1.0 + cc
  defp score(cc, coverage), do: cc * cc * :math.pow(1 - coverage, 3) + cc

  defp violation_for(report, nil), do: [{:new_offender, report}]

  defp violation_for(report, permitted) when report.score > permitted,
    do: [{:baseline_regression, report, permitted}]

  defp violation_for(_report, _permitted), do: []

  defp traverse(
         {:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, [do: body]]},
         scope,
         acc,
         file
       ) do
    traverse(body, scope ++ parts, acc, file)
  end

  defp traverse({op, meta, [call, keywords]}, scope, acc, file)
       when op in @def_ops and is_list(keywords) do
    {name, arity} = name_arity(call)
    node = {op, meta, [call, keywords]}

    clause = %{
      id: function_id(scope, name, arity),
      module: Enum.join(scope, "."),
      name: name,
      arity: arity,
      file: file,
      line: Keyword.get(meta, :line, 0),
      end_line: max_line(node),
      cc: round(CyclomaticComplexity.complexity_for(node))
    }

    [clause | acc]
  end

  defp traverse({_op, _meta, args}, scope, acc, file) when is_list(args) do
    Enum.reduce(args, acc, &traverse(&1, scope, &2, file))
  end

  defp traverse(_other, _scope, acc, _file), do: acc

  defp name_arity({:when, _meta, [call | _guards]}), do: name_arity(call)

  defp name_arity({name, _meta, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity}
  end

  defp function_id(scope, name, arity) do
    "#{Enum.join(scope, ".")}.#{name}/#{arity}"
  end

  defp max_line(node) do
    {_, line} =
      Macro.prewalk(node, 0, fn
        {_op, meta, _args} = ast, acc when is_list(meta) ->
          {ast, max(acc, meta[:line] || 0)}

        ast, acc ->
          {ast, acc}
      end)

    line
  end
end
