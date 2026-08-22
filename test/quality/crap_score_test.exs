defmodule Quality.CrapScoreTest do
  use ExUnit.Case, async: true

  alias ReyCode.Quality.{ChangedCoverage, CrapScore}

  describe "collect/2" do
    test "records public, private, guarded, and zero-arity clauses with arity and line spans" do
      source = """
      defmodule Sample do
        def one do
          :ok
        end

        defp two(a) when is_nil(a), do: a
        def three(), do: :three
      end
      """

      {:ok, clauses} = CrapScore.collect(source, "lib/sample.ex")

      by_id = Map.new(clauses, &{&1.id, &1})

      assert Map.keys(by_id) == ["Sample.one/0", "Sample.three/0", "Sample.two/1"]

      assert %{name: :two, arity: 1, module: "Sample", line: 6, end_line: 6} =
               by_id["Sample.two/1"]

      assert by_id["Sample.one/0"].line == 2
      assert by_id["Sample.one/0"].end_line == 2
      assert by_id["Sample.three/0"].cc == 1
    end

    test "scopes nested modules under their parents" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def nested(a), do: a
        end

        def outer(a), do: a
      end
      """

      {:ok, clauses} = CrapScore.collect(source, "lib/outer.ex")

      assert Enum.map(clauses, & &1.id) == ["Outer.Inner.nested/1", "Outer.outer/1"]
    end

    test "sums decision operators into clause complexity" do
      source = """
      defmodule Branchy do
        def branchy(a) do
          if a do
            case a do
              _ -> :ok
            end
          else
            a || false
          end
        end
      end
      """

      {:ok, [clause]} = CrapScore.collect(source, "lib/branchy.ex")

      assert clause.cc == 4
    end

    test "returns an error for unparsable source" do
      assert {:error, {:invalid_source, "lib/broken.ex"}} =
               CrapScore.collect("defmodule Broken do", "lib/broken.ex")
    end
  end

  describe "scan_files/1" do
    @tag :tmp_dir
    test "reads files and fails on the first unreadable one", %{tmp_dir: tmp_dir} do
      good = Path.join(tmp_dir, "good.ex")
      File.write!(good, "defmodule Good do\n  def a, do: :ok\nend\n")

      assert {:ok, [%{id: "Good.a/0", file: ^good}]} = CrapScore.scan_files([good])
      assert {:error, {:unreadable_file, missing, :enoent}} = CrapScore.scan_files(["missing.ex"])
      assert missing == "missing.ex"
    end
  end

  describe "evaluate/2" do
    test "merges clause complexity and coverage into one sorted report per function" do
      source = """
      defmodule Merged do
        def value(a) do
          if a, do: :one, else: :two
        end

        def value(:other) do
          other = :other
          other
        end
      end
      """

      {:ok, clauses} = CrapScore.collect(source, "lib/merged.ex")

      coverage = %{"lib/merged.ex" => %{2 => 1, 3 => 1, 7 => 0, 8 => 0}}

      [report] = CrapScore.evaluate(clauses, coverage)

      # Clause CCs 2 and 1 merge to 2 + 1 - 1 = 2; coverage 2/4.
      assert report.id == "Merged.value/1"
      assert report.clauses == 2
      assert report.cc == 2
      assert report.coverage == 0.5
      assert report.score == 2 * 2 * 0.125 + 2
      assert report.unmeasured == false
    end

    test "bare-literal bodies carry no line metadata and span the head line only" do
      source = "defmodule Lit do\n  def lit(:x) do\n    :x\n  end\nend\n"

      {:ok, [clause]} = CrapScore.collect(source, "lib/lit.ex")

      assert clause.line == 2
      assert clause.end_line == 2
    end

    test "attributes only in-span LCOV lines and maps through ChangedCoverage.parse_lcov" do
      source = """
      defmodule Spans do
        use GenServer

        def hit(a), do: a

        def miss(a), do: a
      end
      """

      {:ok, clauses} = CrapScore.collect(source, "lib/spans.ex")

      # Line 2 (`use GenServer`) is executable but outside any def span.
      lcov = """
      SF:/workspace/lib/spans.ex
      DA:2,1
      DA:4,1
      DA:6,0
      end_of_record
      """

      coverage = ChangedCoverage.parse_lcov(lcov, "/workspace")

      reports = CrapScore.evaluate(clauses, coverage)
      by_id = Map.new(reports, &{&1.id, &1})

      assert %{covered: 1, total: 1, score: 1.0} = by_id["Spans.hit/1"]
      assert %{covered: 0, total: 1, score: 2.0} = by_id["Spans.miss/1"]
    end

    test "treats functions absent from coverage as unmeasured and fully at risk" do
      source = "defmodule Dark do\n  def dark(a) do\n    if a, do: :ok\n  end\nend\n"

      {:ok, clauses} = CrapScore.collect(source, "lib/dark.ex")

      [report] = CrapScore.evaluate(clauses, %{})

      assert report.cc == 2
      assert report.unmeasured == true
      assert report.coverage == nil
      # Unmeasured counts as zero coverage: CC^2 + CC = 6.
      assert report.score == 6.0
    end
  end

  describe "enforce/3" do
    defp report(id, score), do: %{id: id, file: "lib/x.ex", line: 1, cc: 1, score: score}

    test "passes scores at or below the maximum without baseline entries" do
      reports = [report("A.a/0", 30.0), report("A.b/1", 4.1)]

      assert {:ok, ^reports} = CrapScore.enforce(reports, %{}, 30)
    end

    test "fails new offenders and baseline regressions" do
      reports = [report("A.new/0", 45.0), report("A.old/0", 55.0), report("A.ok/0", 10.0)]

      assert {:error, violations} = CrapScore.enforce(reports, %{"A.old/0" => 50.0}, 30)

      assert [
               {:new_offender, %{id: "A.new/0"}},
               {:baseline_regression, %{id: "A.old/0"}, 50.0}
             ] = violations
    end

    test "accepts legacy offenders within their baseline caps" do
      assert {:ok, _reports} =
               CrapScore.enforce([report("A.old/0", 45.0)], %{"A.old/0" => 45.0}, 30)
    end

    test "reports stale baseline entries for deleted functions" do
      reports = [report("A.kept/0", 1.0)]

      assert CrapScore.stale_entries(reports, %{"A.kept/0" => 45.0, "A.gone/0" => 60.0}) == [
               "A.gone/0"
             ]
    end
  end

  describe "baseline_delta/2" do
    test "accepts removals and reduced caps" do
      base = %{"A.a/0" => 50.0, "A.b/0" => 40.0}
      current = %{"A.b/0" => 35.0}

      assert CrapScore.baseline_delta(current, base) == :ok
    end

    test "rejects additions and raised caps with sorted issues" do
      base = %{"A.a/0" => 50.0}
      current = %{"A.a/0" => 55.0, "A.new/0" => 45.0}

      assert {:error, [raised, added]} = CrapScore.baseline_delta(current, base)
      assert raised =~ "raised for A.a/0: 50.0 -> 55.0"
      assert added =~ "added for A.new/0"
    end
  end

  describe "baseline documents" do
    test "encode_baseline writes only offenders deterministically and decode round-trips" do
      reports = [
        %{id: "A.low/0", file: "lib/a.ex", line: 1, cc: 2, score: 2.0},
        %{id: "B.high/1", file: "lib/b.ex", line: 9, cc: 8, score: 52.0}
      ]

      document = CrapScore.encode_baseline(reports, 30)

      assert document == """
             {
               "functions": {
                 "B.high/1": 52.0
               },
               "threshold": 30
             }
             """

      assert {:ok, %{"B.high/1" => 52.0}, 30} = CrapScore.decode_baseline(document)
    end

    test "decode_baseline rejects malformed documents" do
      assert {:error, :invalid_baseline} = CrapScore.decode_baseline("not json")
      assert {:error, :invalid_baseline} = CrapScore.decode_baseline(~s({"functions": 3}))

      assert {:error, :invalid_baseline} =
               CrapScore.decode_baseline(~s({"functions": {"a/9": "x"}}))
    end
  end
end
