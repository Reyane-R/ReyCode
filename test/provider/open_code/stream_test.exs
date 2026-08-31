defmodule ReyCode.Provider.OpenCode.StreamTest do
  @moduledoc "Stream-level failure mapping for the OpenCode adapter."

  use ExUnit.Case, async: true

  import ReyCode.Test.OpenCodeHelpers, only: [request: 0]

  alias ReyCode.Provider.OpenCode
  alias ReyCode.RuntimeConfig

  test "names the trust setting when the workspace is outside policy" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey-code-opencode-policy-#{System.unique_integer([:positive])}"
      )

    :ok = File.write(path, "#!/bin/sh\nexit 0\n")
    :ok = File.chmod(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    runtime = %ReyCode.Provider.Runtime{
      module: OpenCode,
      executable: path,
      config: RuntimeConfig.fresh().open_code,
      workspace_policy: %RuntimeConfig.Workspace{roots: [System.tmp_dir!()]},
      status: :configured
    }

    outside = File.cwd!()
    request = %{request() | workspace: outside}

    assert {:error, %{category: :invalid_workspace, message: message}} =
             OpenCode.stream(runtime, request, fn _frame -> :ok end)

    assert message =~ "outside ReyCode's trusted roots"
    assert message =~ "REYCODE_WORKSPACE_ROOTS"
    assert message =~ outside
  end
end
