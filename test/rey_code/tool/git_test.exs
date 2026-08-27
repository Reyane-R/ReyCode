defmodule ReyCode.Tool.GitTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  setup do
    workspace = Path.join(System.tmp_dir!(), "rey-code-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "test@example.invalid"])
    git!(workspace, ["config", "user.name", "ReyCode Test"])
    File.write!(Path.join(workspace, "README.txt"), "before\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-m", "initial"])
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "returns structured status and review findings", %{workspace: workspace} do
    File.write!(Path.join(workspace, "README.txt"), "after\n")

    assert {:ok, %Result{ok: true, output: status}} = dispatch(workspace, %{action: "status"})
    assert Jason.decode!(status)["files"] |> Enum.any?(&(&1["path"] == "README.txt"))

    assert {:ok, %Result{ok: true, output: review}} = dispatch(workspace, %{action: "review"})
    assert Jason.decode!(review)["verdict"] == "ship"
  end

  test "requires approval for commit and commits staged changes", %{workspace: workspace} do
    File.write!(Path.join(workspace, "README.txt"), "committed\n")
    git!(workspace, ["add", "README.txt"])
    request = request(workspace, %{action: "commit", message: "update docs"})
    policy = RuntimeConfig.fresh(workspace_roots: [workspace])

    assert {:ask, %Request{tool: "git"}} = ToolRegistry.dispatch(request, policy)
    assert %Result{ok: true} = ToolRegistry.execute(request, policy)
    assert git!(workspace, ["log", "-1", "--format=%s"]) == "update docs\n"
  end

  test "rejects invalid conflict choices", %{workspace: workspace} do
    request =
      request(workspace, %{action: "resolve_conflict", path: "README.txt", choice: "root"})

    assert {:ask, %Request{tool: "git"}} =
             ToolRegistry.dispatch(request, RuntimeConfig.fresh(workspace_roots: [workspace]))
  end

  test "supports diff, log, branches, and conflict inspection", %{workspace: workspace} do
    File.write!(Path.join(workspace, "README.txt"), "changed\n")

    assert {:ok, %Result{ok: true}} = dispatch(workspace, %{action: "diff"})
    assert {:ok, %Result{ok: true}} = dispatch(workspace, %{action: "log", count: "1"})
    assert {:ok, %Result{ok: true}} = dispatch(workspace, %{action: "branches"})

    assert {:ok, %Result{ok: true, output: conflicts}} =
             dispatch(workspace, %{action: "conflicts"})

    assert Jason.decode!(conflicts)["files"] == []
  end

  defp dispatch(workspace, arguments) do
    ToolRegistry.dispatch(
      request(workspace, arguments),
      RuntimeConfig.fresh(workspace_roots: [workspace])
    )
  end

  defp request(workspace, arguments),
    do: Request.new(tool: "git", arguments: arguments, workspace: workspace, roots: [workspace])

  defp git!(workspace, args) do
    {output, 0} =
      System.cmd(System.find_executable("git"), args, cd: workspace, stderr_to_stdout: true)

    output
  end
end
