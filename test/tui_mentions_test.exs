defmodule ReyCode.TUI.MentionsTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Mentions

  setup do
    workspace =
      (System.tmp_dir!() <> "/mentions-test-#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "expands a relative @path", %{workspace: workspace} do
    write_file(Path.join(workspace, "notes.txt"), "hello notes")

    assert {:ok, expanded, [path]} = Mentions.expand("read @notes.txt", workspace)

    assert expanded ==
             "read @notes.txt\n\n#{Path.join(workspace, "notes.txt")}:\n```\nhello notes\n```\n"

    assert path == Path.join(workspace, "notes.txt")
  end

  test "expands an absolute @path inside the workspace", %{workspace: workspace} do
    file = Path.join(workspace, "src/lib.ex")
    write_file(file, "defmodule Lib, do: :ok")

    assert {:ok, expanded, [_]} = Mentions.expand("open @#{file}", workspace)
    assert expanded =~ "defmodule Lib, do: :ok"
  end

  test "expands #path as an attachment alias", %{workspace: workspace} do
    write_file(Path.join(workspace, "context.md"), "context body")

    assert {:ok, expanded, [_]} = Mentions.expand("see #context.md", workspace)
    assert expanded =~ "context body"
  end

  test "expands multiple distinct tokens once each", %{workspace: workspace} do
    write_file(Path.join(workspace, "a.txt"), "AAA")
    write_file(Path.join(workspace, "b.txt"), "BBB")

    assert {:ok, expanded, paths} = Mentions.expand("@a.txt and @b.txt and @a.txt", workspace)
    assert occurrence_count(expanded, "AAA") == 1
    assert occurrence_count(expanded, "BBB") == 1

    assert Enum.sort(paths) ==
             Enum.sort([Path.join(workspace, "a.txt"), Path.join(workspace, "b.txt")])
  end

  test "leaves bodies without mentions untouched", %{workspace: workspace} do
    body = "## Plan\n\njust plain text\n"
    assert {:ok, ^body, []} = Mentions.expand(body, workspace)
  end

  test "leaves markdown headers and bare sigils untouched", %{workspace: workspace} do
    body = "## Heading\n\n# heading\n@ at the start of a line\n"
    assert {:ok, ^body, []} = Mentions.expand(body, workspace)
  end

  test "rejects a missing file with :file_not_found", %{workspace: workspace} do
    assert {:error, {"@missing.txt", :file_not_found}} =
             Mentions.expand("@missing.txt", workspace)
  end

  test "rejects a file outside the workspace", %{workspace: workspace} do
    outside = System.tmp_dir!() <> "/outside-#{System.unique_integer([:positive])}.txt"
    File.write!(outside, "nope")
    on_exit(fn -> File.rm(outside) end)

    token = "@" <> outside
    assert {:error, {^token, :outside_workspace}} = Mentions.expand(token, workspace)
  end

  test "rejects a file over the per-file cap", %{workspace: workspace} do
    write_file(Path.join(workspace, "big.txt"), String.duplicate("x", 100))

    assert {:error, {"@big.txt", :file_too_large}} =
             Mentions.expand("@big.txt", workspace, max_bytes: 10)
  end

  test "rejects an attachment over the total cap", %{workspace: workspace} do
    write_file(Path.join(workspace, "a.txt"), String.duplicate("x", 60))
    write_file(Path.join(workspace, "b.txt"), String.duplicate("y", 60))

    assert {:error, {"@b.txt", :total_too_large}} =
             Mentions.expand("@a.txt @b.txt", workspace, max_total_bytes: 100)
  end

  test "defaults to the configured read cap", %{workspace: workspace} do
    write_file(Path.join(workspace, "mid.txt"), String.duplicate("x", 600_000))

    assert {:error, {"@mid.txt", :file_too_large}} = Mentions.expand("@mid.txt", workspace)
  end

  test "rejects a directory token as unreadable", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "dir"))

    assert {:error, {"@dir", :unreadable}} = Mentions.expand("@dir", workspace)
  end

  defp occurrence_count(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
