defmodule ReyCode.Security.ApprovalRulesTest do
  use ExUnit.Case, async: true

  alias ReyCode.Security.ApprovalRules
  alias ReyCode.ToolRegistry

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "reycode-approval-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".reycode"))
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "allows exact and bounded wildcard Bash commands", %{workspace: workspace} do
    write_rules(workspace, ["git status", "mix test *"])

    assert ApprovalRules.allows?(workspace, call("git status"))
    assert ApprovalRules.allows?(workspace, call("mix test"))
    assert ApprovalRules.allows?(workspace, call("mix test test/example_test.exs:12"))
    refute ApprovalRules.allows?(workspace, call("git status --short"))
    refute ApprovalRules.allows?(workspace, call("mix testing"))

    assert ToolRegistry.authorization(call("mix test test/example_test.exs"), workspace) == :allow
  end

  test "shell control operators and malformed rules fail closed", %{workspace: workspace} do
    write_rules(workspace, ["mix test *"])

    for command <- ["mix test; rm -rf .", "mix test && echo unsafe", "mix test $(whoami)"] do
      refute ApprovalRules.allows?(workspace, call(command))
      assert ToolRegistry.authorization(call(command), workspace) == :ask
    end

    File.write!(rules_path(workspace), ~s({"version":1,"allow":{"bash":["mix * test"]}}))
    assert {:error, :invalid_schema} = ApprovalRules.load(workspace)
    assert ToolRegistry.authorization(call("mix test"), workspace) == :ask
  end

  test "missing and symlinked rule files fail closed", %{workspace: workspace} do
    assert {:error, :missing} = ApprovalRules.load(workspace)
    assert ToolRegistry.authorization(call("git status"), workspace) == :ask

    outside =
      Path.join(
        System.tmp_dir!(),
        "reycode-approval-source-#{System.unique_integer([:positive])}"
      )

    File.write!(outside, Jason.encode!(document(["git status"])))
    on_exit(fn -> File.rm(outside) end)
    :ok = :file.make_symlink(to_charlist(outside), to_charlist(rules_path(workspace)))

    assert {:error, :not_regular} = ApprovalRules.load(workspace)
    assert ToolRegistry.authorization(call("git status"), workspace) == :ask
  end

  test "read-only tools remain allowed and unknown tools remain denied", %{workspace: workspace} do
    write_rules(workspace, ["git status"])

    assert ToolRegistry.authorization(%{tool: "read", arguments: %{}}, workspace) == :allow
    assert ToolRegistry.authorization(%{tool: "unknown", arguments: %{}}, workspace) == :denied
  end

  defp call(command), do: %{tool: "bash", arguments: %{"command" => command}}

  defp write_rules(workspace, patterns) do
    File.write!(rules_path(workspace), Jason.encode!(document(patterns)))
  end

  defp document(patterns), do: %{"version" => 1, "allow" => %{"bash" => patterns}}
  defp rules_path(workspace), do: Path.join(workspace, ".reycode/approval_rules.json")
end
