defmodule Mix.Tasks.Quality.ChangedCoverageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Quality.ChangedCoverage, as: ChangedCoverageTask

  test "includes only ReyCode production Elixir sources" do
    assert ChangedCoverageTask.source_pathspecs() == [":(glob)lib/**/*.ex"]
  end

  @tag :tmp_dir
  test "reports successful coverage through the real Git and file adapters", %{tmp_dir: tmp_dir} do
    %{repo: repo, source: source} = changed_repo!(tmp_dir)
    lcov_path = Path.join(tmp_dir, "covered.lcov")
    File.write!(lcov_path, "SF:#{source}\nDA:2,1\nend_of_record\n")

    output =
      capture_io(fn ->
        File.cd!(repo, fn ->
          ChangedCoverageTask.run([
            "--base",
            "HEAD",
            "--lcov",
            lcov_path,
            "--threshold",
            "90"
          ])
        end)
      end)

    assert output =~ "Changed-line coverage: 100.0% (1/1)"
  end

  @tag :tmp_dir
  test "raises with uncovered lines when the requested threshold is missed", %{tmp_dir: tmp_dir} do
    %{repo: repo, source: source} = changed_repo!(tmp_dir)
    lcov_path = Path.join(tmp_dir, "uncovered.lcov")
    File.write!(lcov_path, "SF:#{source}\nDA:2,0\nend_of_record\n")

    assert_raise Mix.Error, ~r/Changed-line coverage is 0.0% \(0\/1\)/, fn ->
      File.cd!(repo, fn ->
        ChangedCoverageTask.run([
          "--base",
          "HEAD",
          "--lcov",
          lcov_path,
          "--threshold",
          "90"
        ])
      end)
    end
  end

  test "rejects invalid options and a missing base" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      ChangedCoverageTask.run(["--unknown", "value"])
    end

    assert_raise Mix.Error, "--base is required", fn ->
      ChangedCoverageTask.run([])
    end
  end

  @tag :tmp_dir
  test "surfaces Git failures", %{tmp_dir: tmp_dir} do
    %{repo: repo} = changed_repo!(tmp_dir)
    lcov_path = Path.join(tmp_dir, "unused.lcov")
    File.write!(lcov_path, "")

    assert_raise Mix.Error, ~r/git diff failed/, fn ->
      File.cd!(repo, fn ->
        ChangedCoverageTask.run([
          "--base",
          "definitely-not-a-git-reference",
          "--lcov",
          lcov_path
        ])
      end)
    end
  end

  defp changed_repo!(tmp_dir) do
    repo = Path.join(tmp_dir, "repo")
    source = Path.join(repo, "lib/example.ex")
    File.mkdir_p!(Path.dirname(source))

    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "tests@example.invalid"])
    git!(repo, ["config", "user.name", "ReyCode Tests"])
    git!(repo, ["config", "commit.gpgsign", "false"])

    File.write!(source, "defmodule Example do\nend\n")
    git!(repo, ["add", "lib/example.ex"])
    git!(repo, ["commit", "--quiet", "-m", "baseline"])

    File.write!(source, "defmodule Example do\n  def value, do: :ok\nend\n")

    %{repo: repo, source: source}
  end

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
