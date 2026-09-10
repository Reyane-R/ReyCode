defmodule ReyCode.RunTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ReyCode.Run
  alias ReyCode.Orchestration.{DelegationWorktree, Engine}

  test "prints the response and raises on argument errors" do
    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        Run.run(["-p", "Return a short answer", "--timeout-ms", "5000"])
      end)

    assert output != ""
    assert_raise(Mix.Error, fn -> Run.run(["-p", "one", "two"]) end)
  end

  @tag :tmp_dir
  test "actual verified Mix entry point returns harness evidence and leaves source unchanged", %{
    tmp_dir: workspace
  } do
    File.write!(Path.join(workspace, "fixture.txt"), "fixture\n")

    for args <- [
          ["init", "-q"],
          ["add", "fixture.txt"],
          [
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-qm",
            "fixture"
          ]
        ] do
      assert {_output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    assert {:ok, _session_id} =
             Engine.create_blank_session("Verified CLI fixture", workspace)

    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        Run.run([
          "--verified",
          "--workspace",
          workspace,
          "--check",
          "test -f fixture.txt",
          "--json",
          "--timeout-ms",
          "15000",
          "Inspect the fixture without changes"
        ])
      end)

    report = Jason.decode!(output)
    evidence = report["verification"]

    on_exit(fn ->
      DelegationWorktree.cleanup(%{
        source_workspace: evidence["source_workspace"],
        workspace: evidence["workspace"]
      })
    end)

    assert report["outcome"] == "ready"
    assert [%{"exit_code" => 0}] = evidence["baseline"]
    assert [%{"exit_code" => 0}] = evidence["checks"]
    assert evidence["patch"] == ""
    assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace)
  end
end
