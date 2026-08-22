defmodule ReyCode.ToolExecutionTest do
  use ExUnit.Case, async: true

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

  defp run(tool, arguments), do: ToolRegistry.execute(request(tool, arguments))

  test "read returns file contents inside the root" do
    path = Path.join(@workspace, "a.txt")
    File.write!(path, "contents")
    assert %Result{ok: true, output: "contents"} = run("read", %{path: path})
  end

  test "read is denied outside the trusted root" do
    outside = "/etc/passwd"
    assert %Result{ok: false, error: :workspace_outside_policy} = run("read", %{path: outside})
  end

  test "read rejects a missing path argument" do
    assert %Result{ok: false, error: :missing_path} = run("read", %{})
  end

  test "list enumerates a directory" do
    File.write!(Path.join(@workspace, "f1"), "")
    File.write!(Path.join(@workspace, "f2"), "")
    assert %Result{ok: true, output: output} = run("list", %{path: @workspace})
    assert output =~ "f1" and output =~ "f2"
  end

  test "glob expands a pattern" do
    File.write!(Path.join(@workspace, "x.ex"), "")
    File.write!(Path.join(@workspace, "y.ex"), "")
    File.write!(Path.join(@workspace, "z.txt"), "")
    assert %Result{ok: true, output: output} = run("glob", %{path: @workspace, pattern: "*.ex"})
    assert output =~ "x.ex" and output =~ "y.ex"
    refute output =~ "z.txt"
  end

  test "grep finds matching lines" do
    File.write!(Path.join(@workspace, "code.ex"), "def foo, do: 1\ndef bar, do: 2\n")

    assert %Result{ok: true, output: output} =
             run("grep", %{path: @workspace, pattern: "def foo"})

    assert output =~ "code.ex:1:def foo"
  end

  test "grep rejects an invalid regex" do
    assert %Result{ok: false, error: :invalid_pattern} =
             run("grep", %{path: @workspace, pattern: "["})
  end

  test "write creates a file within the root" do
    path = Path.join(@workspace, "created.txt")
    assert %Result{ok: true} = run("write", %{path: path, content: "hi"})
    assert File.read!(path) == "hi"
  end

  test "write is denied outside the root" do
    assert %Result{ok: false, error: :workspace_outside_policy} =
             run("write", %{path: "/tmp/escape.txt", content: "x"})
  end

  test "edit replaces the first occurrence" do
    path = Path.join(@workspace, "t.txt")
    File.write!(path, "aaa bbb aaa")
    assert %Result{ok: true} = run("edit", %{path: path, old_string: "aaa", new_string: "ZZZ"})
    assert File.read!(path) == "ZZZ bbb aaa"
  end

  test "edit reports a missing old_string" do
    path = Path.join(@workspace, "t.txt")
    File.write!(path, "aaa")

    assert %Result{ok: false, error: :old_string_not_found} =
             run("edit", %{path: path, old_string: "nope", new_string: "x"})
  end

  test "bash runs a command and returns stdout" do
    assert %Result{ok: true, output: output} = run("bash", %{command: "echo hello"})
    assert String.trim(output) == "hello"
  end

  test "bash surfaces a non-zero exit as an error result" do
    assert %Result{ok: false, error: %{exit_code: 1}} = run("bash", %{command: "exit 1"})
  end
end
