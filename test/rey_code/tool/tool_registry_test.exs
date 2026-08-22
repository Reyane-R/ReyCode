defmodule ReyCode.ToolRegistryTest do
  use ExUnit.Case, async: true

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

  test "allow-listed tools execute immediately" do
    path = Path.join(@workspace, "note.txt")
    File.write!(path, "hello")
    req = request("read", %{path: path})

    assert {:ok, %Result{ok: true, output: "hello"}} = ToolRegistry.dispatch(req)
  end

  test "bash and write require approval (ask) and are not executed by dispatch" do
    assert {:ask, %Request{tool: "bash"}} =
             ToolRegistry.dispatch(request("bash", %{command: "echo hi"}))

    assert {:ask, %Request{tool: "write"}} =
             ToolRegistry.dispatch(request("write", %{path: "x", content: "y"}))
  end

  test "unknown tool is denied" do
    assert {:deny, :unknown_tool} = ToolRegistry.dispatch(request("rm", %{}))
  end

  test "execute/1 runs an approved tool" do
    path = Path.join(@workspace, "out.txt")

    assert %Result{ok: true} =
             ToolRegistry.execute(request("write", %{path: path, content: "data"}))

    assert File.read!(path) == "data"
  end

  test "allow tools are not approval-required; ask tools are" do
    refute ToolRegistry.requires_approval?("read")
    refute ToolRegistry.requires_approval?("grep")
    assert ToolRegistry.requires_approval?("bash")
    assert ToolRegistry.requires_approval?("write")
  end

  test "tool_names/0 lists the seven supported tools" do
    assert Enum.sort(ToolRegistry.tool_names()) ==
             Enum.sort(["read", "write", "edit", "bash", "grep", "glob", "list"])
  end
end
