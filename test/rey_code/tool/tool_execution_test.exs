defmodule ReyCode.ToolExecutionTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  @root System.tmp_dir!()
  @workspace Path.join(@root, "tool-exec-ws")

  setup do
    File.rm_rf!(@workspace)
    File.mkdir_p!(@workspace)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  defp request(tool, arguments) do
    Request.new(tool: tool, arguments: arguments, workspace: @workspace, roots: [@root])
  end

  defp run(tool, arguments, overrides \\ []) do
    policy = RuntimeConfig.fresh(Keyword.put(overrides, :workspace_roots, [@root]))
    ToolRegistry.execute(request(tool, arguments), policy)
  end

  defp escape_root(tag),
    do:
      Path.join(
        System.user_home!(),
        "reycode-tool-escape-#{tag}-#{System.unique_integer([:positive])}"
      )

  describe "read" do
    test "returns file contents inside the root" do
      path = Path.join(@workspace, "a.txt")
      File.write!(path, "contents")
      assert %Result{ok: true, output: "contents"} = run("read", %{path: path})
    end

    test "is denied outside the trusted root" do
      outside = "/etc/passwd"
      assert %Result{ok: false, error: :workspace_outside_policy} = run("read", %{path: outside})
    end

    test "rejects a missing path argument" do
      assert %Result{ok: false, error: :missing_path} = run("read", %{})
    end

    test "reads a bounded line window with offset and limit" do
      path = Path.join(@workspace, "lines.txt")
      File.write!(path, Enum.map_join(1..10, "\n", &"line #{&1}") <> "\n")

      assert %Result{ok: true, output: output, truncated: true, metadata: metadata} =
               run("read", %{path: path, offset: 3, limit: 2})

      assert output == "line 3\nline 4\n"
      assert metadata == %{"offset" => 3, "lines" => 2, "bytes" => byte_size(output)}
    end

    test "does not flag truncation when the window reaches end of file" do
      path = Path.join(@workspace, "short.txt")
      File.write!(path, "one\ntwo\n")

      assert %Result{ok: true, output: "two\n", truncated: false} =
               run("read", %{path: path, offset: 2})
    end

    test "flags truncation when content remains beyond the window" do
      path = Path.join(@workspace, "lines.txt")
      File.write!(path, "a\nb\nc\n")

      assert %Result{ok: true, output: "a\nb\n", truncated: true} =
               run("read", %{path: path, limit: 2})
    end

    test "rejects binary files instead of returning garbled bytes" do
      path = Path.join(@workspace, "blob.bin")
      File.write!(path, <<0, 1, 2, 3>>)

      assert %Result{ok: false, error: :binary_file} = run("read", %{path: path})
    end

    test "rejects invalid window arguments" do
      path = Path.join(@workspace, "a.txt")
      File.write!(path, "x")

      assert %Result{ok: false, error: :invalid_offset} =
               run("read", %{path: path, offset: -1})

      assert %Result{ok: false, error: :invalid_limit} = run("read", %{path: path, limit: "abc"})
    end
  end

  test "list enumerates a directory" do
    File.write!(Path.join(@workspace, "f1"), "")
    File.write!(Path.join(@workspace, "f2"), "")
    assert %Result{ok: true, output: output} = run("list", %{path: @workspace})
    assert output =~ "f1" and output =~ "f2"
  end

  describe "glob" do
    test "expands a pattern" do
      File.write!(Path.join(@workspace, "x.ex"), "")
      File.write!(Path.join(@workspace, "y.ex"), "")
      File.write!(Path.join(@workspace, "z.txt"), "")

      assert %Result{ok: true, output: output, metadata: %{"matches" => 2}} =
               run("glob", %{path: @workspace, pattern: "*.ex"})

      assert output =~ "x.ex" and output =~ "y.ex"
      refute output =~ "z.txt"
    end

    test "rejects patterns that escape the workspace" do
      assert %Result{ok: false, error: :invalid_pattern} =
               run("glob", %{path: @workspace, pattern: "../**/*.ex"})

      assert %Result{ok: false, error: :invalid_pattern} =
               run("glob", %{path: @workspace, pattern: "/etc/*"})
    end

    test "drops symlinked results that resolve outside the roots" do
      outside = escape_root("glob")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      File.write!(Path.join(outside, "leak.txt"), "")
      :ok = :file.make_symlink(to_charlist(outside), to_charlist(Path.join(@workspace, "link")))

      assert %Result{ok: true, output: output} =
               run("glob", %{path: @workspace, pattern: "link/**"})

      assert output == ""
    end
  end

  describe "grep" do
    test "finds matching lines" do
      File.write!(Path.join(@workspace, "code.ex"), "def foo, do: 1\ndef bar, do: 2\n")

      assert %Result{
               ok: true,
               output: output,
               metadata: %{"files_scanned" => 1, "binary_files_skipped" => 0}
             } = run("grep", %{path: @workspace, pattern: "def foo"})

      assert output =~ "code.ex:1:def foo"
    end

    test "scans a single file target" do
      file = Path.join(@workspace, "single.ex")
      File.write!(file, "target_line\n")

      assert %Result{ok: true, output: output} =
               run("grep", %{path: file, pattern: "target_line"})

      assert output =~ ~r{single\.ex:1:target_line$}
    end

    test "skips binary files and symlinks out of the workspace" do
      File.write!(Path.join(@workspace, "blob.bin"), <<0, 255>> <> "needle")

      outside = escape_root("grep")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      File.write!(Path.join(outside, "secret.txt"), "needle\n")
      :ok = :file.make_symlink(to_charlist(outside), to_charlist(Path.join(@workspace, "link")))

      assert %Result{
               ok: true,
               output: "",
               metadata: %{"binary_files_skipped" => 1}
             } = run("grep", %{path: @workspace, pattern: "needle"})
    end

    test "rejects an invalid regex" do
      assert %Result{ok: false, error: :invalid_pattern} =
               run("grep", %{path: @workspace, pattern: "["})
    end
  end

  describe "write" do
    test "creates a file within the root" do
      path = Path.join(@workspace, "created.txt")

      assert %Result{ok: true, metadata: %{"bytes" => 2}} =
               run("write", %{path: path, content: "hi"})

      assert File.read!(path) == "hi"
    end

    test "is denied outside the root" do
      assert %Result{ok: false, error: :workspace_outside_policy} =
               run("write", %{path: "/tmp/escape.txt", content: "x"})
    end

    test "caps oversized content before touching the filesystem" do
      assert %Result{ok: false, error: :content_too_large} =
               run(
                 "write",
                 %{
                   path: Path.join(@workspace, "big.txt"),
                   content: String.duplicate("x", 17)
                 },
                 tool_write_max_bytes: 16
               )
    end
  end

  describe "edit" do
    test "replaces a unique occurrence" do
      path = Path.join(@workspace, "t.txt")
      File.write!(path, "aaa bbb ccc")

      assert %Result{ok: true, metadata: %{"occurrences" => 1}} =
               run("edit", %{path: path, old_string: "bbb", new_string: "ZZZ"})

      assert File.read!(path) == "aaa ZZZ ccc"
    end

    test "rejects ambiguous matches without writing" do
      path = Path.join(@workspace, "t.txt")
      File.write!(path, "aaa bbb aaa")

      assert %Result{ok: false, error: :ambiguous_match} =
               run("edit", %{path: path, old_string: "aaa", new_string: "ZZZ"})

      assert File.read!(path) == "aaa bbb aaa"
    end

    test "reports a missing old_string" do
      path = Path.join(@workspace, "t.txt")
      File.write!(path, "aaa")

      assert %Result{ok: false, error: :old_string_not_found} =
               run("edit", %{path: path, old_string: "nope", new_string: "x"})
    end
  end

  describe "bash" do
    test "runs a command and returns stdout with execution metadata" do
      assert %Result{ok: true, output: output, truncated: false, metadata: metadata} =
               run("bash", %{command: "echo hello"})

      assert String.trim(output) == "hello"

      assert %{"exit_code" => 0, "timed_out" => false, "wall_time_ms" => ms} = metadata
      assert is_integer(ms)
    end

    test "surfaces a non-zero exit with stderr captured" do
      assert %Result{ok: false, error: error} =
               run("bash", %{command: "echo boom >&2; exit 3"})

      assert error["exit_code"] == 3
      assert error["stderr"] =~ "boom"
      assert error["output"] == ""
    end

    @tag :timeout_kill
    test "kills timed-out process trees and reports the timeout" do
      flag = Path.join(@workspace, "survivor.flag")

      # The background subshell would create the flag 500ms in; a tree kill
      # must prevent that even though only the parent hit the timeout.
      assert %Result{ok: false, error: error, metadata: metadata} =
               run(
                 "bash",
                 %{command: "(sleep 0.5 && touch #{flag}) & sleep 60"},
                 tool_bash_timeout_ms: 300
               )

      assert error["reason"] == "timeout"
      assert error["exit_code"] in [137, 143]
      assert metadata["timed_out"] == true
      # Teardown must be prompt relative to the 60s child, even on a busy
      # machine where signal escalation takes a few extra seconds.
      assert metadata["wall_time_ms"] < 30_000

      Process.sleep(1_000)
      refute File.exists?(flag), "background child survived the timeout teardown"
    end

    @tag :output_cap
    test "caps unbounded output and marks truncation" do
      assert %Result{ok: true, truncated: true, output: output, metadata: metadata} =
               run("bash", %{command: "yes x | head -c 100000"},
                 tool_bash_max_output_bytes: 1_000
               )

      assert byte_size(output) <= 1_050
      assert output =~ "[output truncated"
      assert metadata["exit_code"] == 0
    end

    test "rejects a missing command" do
      assert %Result{ok: false, error: :missing_command} = run("bash", %{})
    end
  end
end
