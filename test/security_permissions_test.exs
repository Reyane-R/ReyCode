defmodule ReyCode.Security.PermissionsTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Security.Permissions
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  setup do
    workspace = Path.join(System.tmp_dir!(), "permissions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "default dispatch writes and runs shell commands immediately", %{workspace: workspace} do
    config = RuntimeConfig.fresh(workspace_roots: [workspace])

    request =
      Request.new(
        tool: "write",
        workspace: workspace,
        arguments: %{"path" => "hello.txt", "content" => "hello"}
      )

    assert {:ok, %Result{ok: true}} = ToolRegistry.dispatch(request, config)
    assert File.read!(Path.join(workspace, "hello.txt")) == "hello"

    shell =
      Request.new(tool: "bash", workspace: workspace, arguments: %{"command" => "printf ready"})

    assert {:ok, %Result{ok: true, output: "ready"}} = ToolRegistry.dispatch(shell, config)
  end

  test "ask and deny perform no write, and unknown tools remain distinct", %{workspace: workspace} do
    request =
      Request.new(
        tool: "write",
        workspace: workspace,
        arguments: %{"path" => "out", "content" => "data"}
      )

    asking = RuntimeConfig.fresh(tool_permissions: %{default: :ask, rules: []})
    denying = RuntimeConfig.fresh(tool_permissions: %{default: :deny, rules: []})
    assert {:ask, _} = ToolRegistry.dispatch(request, asking)
    assert {:deny, :permission_denied} = ToolRegistry.dispatch(request, denying)
    refute File.exists?(Path.join(workspace, "out"))
    assert {:deny, :unknown_tool} = ToolRegistry.dispatch(%{request | tool: "unknown"}, denying)
  end

  test "last matching input rule wins and legacy rules cannot override deny", %{
    workspace: workspace
  } do
    permissions =
      Permissions.new!(%{
        default: :allow,
        rules: [
          %{tool: "bash", action: :ask},
          %{tool: "bash", pattern: "git *", action: :allow},
          %{tool: "bash", pattern: "git push*", action: :deny},
          %{tool: "write", pattern: "private/*", action: :deny}
        ]
      })

    File.mkdir_p!(Path.join(workspace, ".reycode"))

    File.write!(
      Path.join(workspace, ".reycode/approval_rules.json"),
      Jason.encode!(%{"version" => 1, "allow" => %{"bash" => ["git push"]}})
    )

    assert Permissions.decide(
             permissions,
             %{tool: "bash", arguments: %{"command" => "git status"}},
             workspace
           ) == :allow

    assert Permissions.decide(
             permissions,
             %{tool: "bash", arguments: %{"command" => "git push"}},
             workspace
           ) == :denied

    assert Permissions.decide(
             permissions,
             %{tool: "bash", arguments: %{command: "mix test"}},
             workspace
           ) == :ask

    assert Permissions.decide(
             permissions,
             %{tool: "write", arguments: %{"path" => "private/key"}},
             workspace
           ) == :denied
  end

  test "path aliases and symlinks cannot bypass a denial", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "private"))
    File.write!(Path.join(workspace, "private/key"), "secret")
    File.ln_s!("private", Path.join(workspace, "alias"))

    policy =
      Permissions.new!(%{
        default: :allow,
        rules: [%{tool: "write", action: :deny, pattern: "private/*"}]
      })

    for path <- ["private/key", "./private/key", "alias/key", Path.join(workspace, "private/key")] do
      assert Permissions.decide(policy, %{tool: "write", arguments: %{"path" => path}}, workspace) ==
               :denied
    end
  end

  test "complex wildcard matches and oversized input fail closed", %{workspace: workspace} do
    policy =
      Permissions.new!(%{
        default: :allow,
        rules: [%{tool: "bash", action: :deny, pattern: String.duplicate("*a", 30) <> "b*"}]
      })

    assert Permissions.decide(
             policy,
             %{tool: "bash", arguments: %{command: String.duplicate("a", 100) <> "b"}},
             workspace
           ) == :denied

    assert Permissions.decide(
             policy,
             %{tool: "bash", arguments: %{command: String.duplicate("x", 128_001)}},
             workspace
           ) == :denied
  end

  test "invalid and oversized policies fail at config construction" do
    for value <- [
          %{},
          %{default: :oops, rules: []},
          %{default: :allow, rules: [%{tool: "bash", action: :oops}]},
          %{default: :allow, rules: List.duplicate(%{tool: "bash", action: :ask}, 129)}
        ] do
      assert_raise ArgumentError, ~r/tool_permissions/, fn ->
        RuntimeConfig.fresh(tool_permissions: value)
      end
    end
  end

  test "an approved file request is rechecked when its symlink target changes", %{
    workspace: workspace
  } do
    File.mkdir_p!(Path.join(workspace, "private"))
    File.write!(Path.join(workspace, "allowed"), "before")
    File.write!(Path.join(workspace, "private/key"), "secret")
    link = Path.join(workspace, "link")
    File.ln_s!("allowed", link)

    config =
      RuntimeConfig.fresh(
        workspace_roots: [workspace],
        tool_permissions: %{
          default: :ask,
          rules: [%{tool: "write", pattern: "private/*", action: :deny}]
        }
      )

    request =
      Request.new(
        tool: "write",
        workspace: workspace,
        arguments: %{"path" => "link", "content" => "changed"}
      )

    assert {:ask, approved} = ToolRegistry.dispatch(request, config)
    File.rm!(link)
    File.ln_s!("private/key", link)
    assert %Result{ok: false, error: :permission_denied} = ToolRegistry.execute(approved, config)
    assert File.read!(Path.join(workspace, "private/key")) == "secret"
  end

  test "patterns on tools without a single path or command target are rejected" do
    for tool <- ["lsp", "git", "eval", "process", "memory", "*"] do
      assert_raise ArgumentError, fn ->
        Permissions.new!(%{
          default: :allow,
          rules: [%{tool: tool, action: :deny, pattern: "private/*"}]
        })
      end
    end
  end

  test "matcher exhaustion denies even when a later rule allows", %{workspace: workspace} do
    policy =
      Permissions.new!(%{
        default: :allow,
        rules: [
          %{tool: "bash", action: :deny, pattern: "*" <> String.duplicate("a", 500) <> "b"},
          %{tool: "bash", action: :allow}
        ]
      })

    assert Permissions.decide(
             policy,
             %{tool: "bash", arguments: %{command: String.duplicate("a", 10_000)}},
             workspace
           ) == :denied
  end
end
