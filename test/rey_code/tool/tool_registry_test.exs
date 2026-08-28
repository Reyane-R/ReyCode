defmodule ReyCode.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  @root System.tmp_dir!()
  @workspace Path.join(@root, "tool-registry-ws")

  setup do
    File.rm_rf!(@workspace)
    File.mkdir_p!(@workspace)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  defp request(tool, arguments) do
    Request.new(tool: tool, arguments: arguments, workspace: @workspace, roots: [@root])
  end

  defp policy, do: RuntimeConfig.fresh(workspace_roots: [@root])

  test "allow-listed tools execute immediately" do
    path = Path.join(@workspace, "note.txt")
    File.write!(path, "hello")
    req = request("read", %{path: path})

    assert {:ok, %Result{ok: true, output: "hello"}} = ToolRegistry.dispatch(req, policy())
  end

  test "bash and write require approval (ask) and are not executed by dispatch" do
    assert {:ask, %Request{tool: "bash"}} =
             ToolRegistry.dispatch(request("bash", %{command: "echo hi"}), policy())

    assert {:ask, %Request{tool: "write"}} =
             ToolRegistry.dispatch(request("write", %{path: "x", content: "y"}), policy())
  end

  test "unknown tool is denied" do
    assert {:deny, :unknown_tool} = ToolRegistry.dispatch(request("rm", %{}), policy())
  end

  test "execute/2 runs an approved tool" do
    path = Path.join(@workspace, "out.txt")

    assert %Result{ok: true} =
             ToolRegistry.execute(request("write", %{path: path, content: "data"}), policy())

    assert File.read!(path) == "data"
  end

  test "allow tools are not approval-required; ask tools are" do
    refute ToolRegistry.requires_approval?("read")
    refute ToolRegistry.requires_approval?("grep")
    assert ToolRegistry.requires_approval?("bash")
    assert ToolRegistry.requires_approval?("write")
  end

  test "only mutating LSP requests require approval" do
    refute ToolRegistry.requires_approval?(
             request("lsp", %{action: "references", file: "lib/a.ex", line: 1})
           )

    assert ToolRegistry.requires_approval?(
             request("lsp", %{action: "rename", file: "lib/a.ex", line: 1, new_name: "next"})
           )
  end

  test "process state changes require approval while inspection remains read-only" do
    refute ToolRegistry.requires_approval?(request("process", %{action: "logs", name: "web"}))

    assert ToolRegistry.requires_approval?(
             request("process", %{action: "start", name: "web", command: ["echo", "ok"]})
           )
  end

  test "tool_names/0 lists the sixteen supported tools" do
    assert Enum.sort(ToolRegistry.tool_names()) ==
             Enum.sort([
               "artifact_read",
               "read",
               "write",
               "edit",
               "bash",
               "grep",
               "glob",
               "list",
               "lsp",
               "process",
               "git",
               "debug",
               "eval",
               "memory",
               "web_search",
               "read_url"
             ])
  end
end
