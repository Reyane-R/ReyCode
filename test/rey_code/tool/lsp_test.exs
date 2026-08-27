defmodule ReyCode.Tool.LSPTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "rey-code-lsp-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "returns bounded read-only LSP results", %{workspace: workspace} do
    file = Path.join(workspace, "sample.ex")
    File.write!(file, "value = 1\n")

    response = [%{"uri" => file_uri(file), "range" => range(0, 0, 0, 5)}]
    server = fake_server(workspace, response)
    policy = policy(workspace, server)
    request = request(workspace, "references", file)

    assert {:ok, %Result{ok: true, output: output}} = ToolRegistry.dispatch(request, policy)
    assert Jason.decode!(output) == response
  end

  test "rename requires approval and applies validated workspace edits", %{workspace: workspace} do
    file = Path.join(workspace, "sample.ex")
    File.write!(file, "alpha = 1\n")

    response = %{
      "changes" => %{
        file_uri(file) => [
          %{"range" => range(0, 0, 0, 5), "newText" => "beta"}
        ]
      }
    }

    server = fake_server(workspace, response)
    policy = policy(workspace, server)

    request =
      request(workspace, "rename", file, %{"new_name" => "beta"})

    assert {:ask, %Request{tool: "lsp"}} = ToolRegistry.dispatch(request, policy)

    assert %Result{ok: true, metadata: %{"files" => 1, "edits" => 1}} =
             ToolRegistry.execute(request, policy)

    assert File.read!(file) == "beta = 1\n"
  end

  test "fails explicitly when no language server is configured", %{workspace: workspace} do
    file = Path.join(workspace, "sample.ex")
    File.write!(file, "value = 1\n")
    policy = RuntimeConfig.fresh(workspace_roots: [workspace])

    assert {:ok, %Result{ok: false, error: :lsp_not_configured}} =
             ToolRegistry.dispatch(request(workspace, "hover", file), policy)
  end

  defp request(workspace, action, file, extra \\ %{}) do
    arguments = Map.merge(%{"action" => action, "file" => file, "line" => 1}, extra)
    Request.new(tool: "lsp", arguments: arguments, workspace: workspace, roots: [workspace])
  end

  defp policy(workspace, server) do
    RuntimeConfig.fresh(
      workspace_roots: [workspace],
      tool_lsp_command: [server],
      tool_lsp_timeout_ms: 10_000
    )
  end

  defp fake_server(workspace, operation_result) do
    path = Path.join(workspace, "fake-lsp-#{System.unique_integer([:positive])}")

    initialize =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"capabilities" => %{}}})

    operation = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => operation_result})

    script = """
    #!/bin/bash
    set -eu
    read_frame() {
      IFS= read -r header
      header="${header%$'\\r'}"
      length="${header#Content-Length: }"
      IFS= read -r _blank
      dd bs=1 count="$length" 2>/dev/null
    }
    respond() {
      body="$1"
      printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    }
    read_frame >/dev/null
    respond '#{initialize}'
    read_frame >/dev/null
    read_frame >/dev/null
    read_frame >/dev/null
    respond '#{operation}'
    sleep 1
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end

  defp range(start_line, start_character, end_line, end_character) do
    %{
      "start" => %{"line" => start_line, "character" => start_character},
      "end" => %{"line" => end_line, "character" => end_character}
    }
  end

  defp file_uri(path), do: "file://" <> URI.encode(Path.expand(path))
end
