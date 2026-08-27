defmodule ReyCode.Tool.DebugTest do
  use ExUnit.Case, async: true

  alias ReyCode.DebuggerHub
  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  test "routes bounded DAP requests through a supervised session" do
    workspace = temp_dir()
    server = fake_server(workspace)
    name = "debug-#{System.unique_integer([:positive])}"
    policy = RuntimeConfig.fresh(workspace_roots: [workspace], tool_debugger_command: [server])

    request =
      Request.new(
        tool: "debug",
        arguments: %{action: "start", name: name},
        workspace: workspace,
        roots: [workspace]
      )

    assert {:ask, %Request{tool: "debug"}} = ToolRegistry.dispatch(request, policy)
    assert %Result{ok: true} = ToolRegistry.execute(request, policy)
    assert {:ok, %{"threads" => [%{"id" => 1}]}} = DebuggerHub.request(name, "threads", %{})
    assert :ok = DebuggerHub.stop(name)
    File.rm_rf!(workspace)
  end

  test "times out a debugger request" do
    workspace = temp_dir()
    server = silent_server(workspace)

    policy =
      RuntimeConfig.fresh(tool_debugger_command: [server], tool_debugger_timeout_ms: 20).tools.debugger

    name = "timeout-#{System.unique_integer([:positive])}"

    assert {:ok, _} = DebuggerHub.start(name, [server], workspace, policy)
    assert {:error, :debugger_timeout} = DebuggerHub.request(name, "threads", %{})
    assert :ok = DebuggerHub.stop(name)
    File.rm_rf!(workspace)
  end

  defp temp_dir do
    path = Path.join(System.tmp_dir!(), "rey-code-debug-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp silent_server(workspace) do
    path = Path.join(workspace, "silent-dap")
    File.write!(path, "#!/bin/sh\nsleep 2\n")
    File.chmod!(path, 0o700)
    path
  end

  defp fake_server(workspace) do
    path = Path.join(workspace, "fake-dap")

    script = """
    #!/bin/bash
    set -eu
    while IFS= read -r header; do
      header="${header%$'\\r'}"
      length="${header#Content-Length: }"
      IFS= read -r _blank
      body=$(dd bs=1 count="$length" 2>/dev/null)
      seq=$(printf '%s' "$body" | sed -n 's/.*"seq":\\([0-9][0-9]*\\).*/\\1/p')
      command=$(printf '%s' "$body" | sed -n 's/.*"command":"\\([^\"]*\\)".*/\\1/p')
      if [ "$command" = "threads" ]; then
        result='{"threads":[{"id":1,"name":"main"}]}'
      else
        result='{"capabilities":{}}'
      fi
      response="{\\"type\\":\\"response\\",\\"request_seq\\":$seq,\\"success\\":true,\\"command\\":\\"$command\\",\\"body\\":$result}"
      printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#response}" "$response"
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end
end
