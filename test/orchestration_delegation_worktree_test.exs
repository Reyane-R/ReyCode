defmodule ReyCode.Orchestration.DelegationWorktreeTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.DelegationWorktree

  test "previews, idempotently applies, and retains an isolated patch until cleanup" do
    git = System.find_executable("git")
    assert is_binary(git)

    workspace =
      Path.join(System.tmp_dir!(), "rey-code-worktree-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sample.txt"), "before\n")
    git!(git, workspace, ["init"])
    git!(git, workspace, ["config", "user.email", "reycode@example.invalid"])
    git!(git, workspace, ["config", "user.name", "ReyCode Test"])
    git!(git, workspace, ["add", "sample.txt"])
    git!(git, workspace, ["commit", "-m", "initial"])
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, isolation} = DelegationWorktree.create(workspace, "inv-child")
    File.write!(Path.join(isolation.workspace, "sample.txt"), "after\n")

    assert File.read!(Path.join(workspace, "sample.txt")) == "before\n"
    assert {:ok, preview} = DelegationWorktree.preview(isolation)
    assert preview =~ "sample.txt"
    assert preview =~ "-before"
    assert preview =~ "+after"

    assert :ok = DelegationWorktree.apply_keep(isolation)
    assert File.read!(Path.join(workspace, "sample.txt")) == "after\n"
    assert File.exists?(isolation.workspace)
    assert :ok = DelegationWorktree.apply_keep(isolation)
    assert :ok = DelegationWorktree.cleanup(isolation)
    refute File.exists?(isolation.workspace)
    assert :ok = DelegationWorktree.cleanup(isolation)
  end

  test "discard removes an isolated worktree without applying its patch" do
    git = System.find_executable("git")

    workspace =
      Path.join(System.tmp_dir!(), "rey-code-discard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sample.txt"), "before\n")
    git!(git, workspace, ["init"])
    git!(git, workspace, ["config", "user.email", "reycode@example.invalid"])
    git!(git, workspace, ["config", "user.name", "ReyCode Test"])
    git!(git, workspace, ["add", "sample.txt"])
    git!(git, workspace, ["commit", "-m", "initial"])
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, isolation} = DelegationWorktree.create(workspace, "inv-discard")
    File.write!(Path.join(isolation.workspace, "sample.txt"), "discarded\n")
    assert :ok = DelegationWorktree.cleanup(isolation)
    assert File.read!(Path.join(workspace, "sample.txt")) == "before\n"
  end

  defp git!(git, workspace, args) do
    assert {_output, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
  end
end
