defmodule ReyCode.Quality.ChangedCoverageTest do
  use ExUnit.Case, async: true

  alias ReyCode.Quality.ChangedCoverage

  @root "/workspace"

  test "parses absolute LCOV paths and changed hunk ranges" do
    lcov = """
    SF:/workspace/lib/example.ex
    DA:10,1
    DA:11,0
    DA:12,4
    LF:3
    LH:2
    end_of_record
    """

    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -8,0 +10,3 @@
    """

    coverage = ChangedCoverage.parse_lcov(lcov, @root)
    changed = ChangedCoverage.parse_diff(diff)

    assert coverage["lib/example.ex"] == %{10 => 1, 11 => 0, 12 => 4}
    assert changed["lib/example.ex"] == MapSet.new([10, 11, 12])

    assert ChangedCoverage.evaluate(coverage, changed) == %{
             covered: 2,
             total: 3,
             percent: 66.7,
             uncovered: [{"lib/example.ex", 11}]
           }
  end

  test "ignores changed comments and blank lines absent from LCOV" do
    lcov = """
    SF:lib/example.ex
    DA:5,1
    end_of_record
    """

    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -1,0 +3,3 @@
    """

    report =
      lcov
      |> ChangedCoverage.parse_lcov(@root)
      |> ChangedCoverage.evaluate(ChangedCoverage.parse_diff(diff))

    assert report == %{covered: 1, total: 1, percent: 100.0, uncovered: []}
  end

  test "check fails below the requested threshold and passes empty executable diffs" do
    lcov = "SF:/workspace/lib/example.ex\nDA:7,0\nend_of_record\n"
    diff = "+++ b/lib/example.ex\n@@ -6,0 +7 @@\n"

    assert {:error, %{percent: +0.0}} = ChangedCoverage.check(lcov, diff, 90, @root)
    assert {:ok, %{percent: 100.0, total: 0}} = ChangedCoverage.check(lcov, "", 90, @root)
  end

  test "deleted files and zero-length new hunks add no changed lines" do
    diff = """
    diff --git a/lib/removed.ex b/lib/removed.ex
    --- a/lib/removed.ex
    +++ /dev/null
    @@ -1,2 +0,0 @@
    """

    assert ChangedCoverage.parse_diff(diff) == %{}
  end

  test "ignores malformed LCOV records and malformed or empty diff hunks" do
    lcov = "SF:/workspace/lib/example.ex\nDA:\nDA:not-a-line,3\nDA:2,4,checksum\n"

    diff = """
    +++ b/lib/example.ex
    @@ malformed @@
    @@ -3,2 +4,0 @@
    """

    assert ChangedCoverage.parse_lcov(lcov, @root) == %{"lib/example.ex" => %{2 => 4}}
    assert ChangedCoverage.parse_diff(diff) == %{"lib/example.ex" => MapSet.new()}
  end

  test "reports uncovered lines in deterministic file and line order" do
    coverage = %{"lib/z.ex" => %{9 => 0}, "lib/a.ex" => %{4 => 0, 2 => 0}}

    changed = %{
      "lib/z.ex" => MapSet.new([9]),
      "lib/a.ex" => MapSet.new([4, 2])
    }

    assert ChangedCoverage.evaluate(coverage, changed).uncovered == [
             {"lib/a.ex", 2},
             {"lib/a.ex", 4},
             {"lib/z.ex", 9}
           ]
  end
end
