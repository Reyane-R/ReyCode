defmodule ReyCode.Provider.OMPTest do
  use ExUnit.Case, async: true

  import ReyCode.Test.OpenCodeHelpers, only: [request: 0]

  alias ReyCode.Provider.OMP
  alias ReyCode.Provider.OMP.{Discovery, Protocol}
  alias ReyCode.RuntimeConfig

  test "parses OMP model discovery responses" do
    output =
      [
        %{type: "ready", protocolVersion: 1},
        %{
          type: "response",
          command: "get_available_models",
          success: true,
          data: %{
            models: [%{provider: "openai", id: "gpt-5"}, %{provider: "anthropic", id: "sonnet"}]
          }
        }
      ]
      |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

    assert Discovery.parse_models(output) == ["anthropic/sonnet", "openai/gpt-5"]
    assert Discovery.parse_models("openai (1)\n│ model │\n│ gpt-5 │") == ["openai/gpt-5"]
  end

  test "maps OMP text deltas into normalized provider frames" do
    state = Protocol.new(request(), RuntimeConfig.fresh().omp)

    emit = fn frame ->
      send(self(), {:frame, frame})
      :ok
    end

    {:cont, state} =
      Protocol.fold(
        {:stdout,
         ~s({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello"}}\n)},
        state,
        emit
      )

    {:halt, state} = Protocol.fold({:exit, {:status, 0}}, state, emit)

    assert_receive {:frame, %{kind: :text_delta, sequence: 1, data: %{text: "Hello"}}}
    assert {:ok, %{}} = Protocol.finish(state)
  end

  test "returns provider errors from failed RPC responses" do
    state = Protocol.new(request(), RuntimeConfig.fresh().omp)
    emit = fn _frame -> :ok end

    {:cont, state} =
      Protocol.fold(
        {:stdout, ~s({"type":"response","success":false,"error":"bad key"}\n)},
        state,
        emit
      )

    {:halt, state} = Protocol.fold({:exit, {:status, 0}}, state, emit)

    assert {:error, %{category: :provider_error, message: "bad key"}} = Protocol.finish(state)
  end

  test "bounds OMP diagnostics on failed process output" do
    config = RuntimeConfig.fresh(omp_max_diagnostic_bytes: 10).omp
    state = Protocol.new(request(), config)
    emit = fn _frame -> :ok end

    {:cont, state} = Protocol.fold({:stderr, "\n"}, state, emit)
    {:cont, state} = Protocol.fold({:stderr, "authentication failed\n"}, state, emit)
    {:cont, state} = Protocol.fold({:stderr, "ignored diagnostics"}, state, emit)
    {:halt, state} = Protocol.fold({:exit, {:status, 7}}, state, emit)

    assert {:error, %{category: :command_failed, message: message}} = Protocol.finish(state)
    assert message =~ "authentica"
    assert message =~ "diagnostics truncated"
  end

  test "streams one round through an OMP RPC executable" do
    path = Path.join(System.tmp_dir!(), "rey-code-omp-test-#{System.unique_integer([:positive])}")

    output =
      ~s({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hello"}})

    :ok = File.write(path, "#!/bin/sh\nprintf '%s\\n' '#{output}'\n")
    :ok = File.chmod(path, 0o700)

    parent = self()
    on_exit(fn -> File.rm(path) end)

    config = RuntimeConfig.fresh()

    request = %{
      request()
      | participant: %{request().participant | provider: :omp, model: "openai/gpt-5"}
    }

    runtime = %ReyCode.Provider.Runtime{
      module: OMP,
      executable: path,
      config: config.omp,
      workspace_policy: config.workspace,
      status: :configured
    }

    assert {:ok, %{}} =
             OMP.stream(runtime, request, fn frame ->
               send(parent, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "hello"}}}
  end

  test "discovers models from an OMP RPC executable" do
    path =
      Path.join(System.tmp_dir!(), "rey-code-omp-discovery-#{System.unique_integer([:positive])}")

    response =
      ~s({"type":"response","command":"get_available_models","success":true,"data":{"models":[{"provider":"openai","id":"gpt-5"}]}})

    :ok = File.write(path, "#!/bin/sh\nprintf '%s\\n' '#{response}'\n")
    :ok = File.chmod(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    config = RuntimeConfig.fresh()

    assert {:ok, %{models: ["openai/gpt-5"], executable: executable}} =
             OMP.discover(executable: path, omp: config.omp, providers: config.providers)

    assert Path.basename(executable) == Path.basename(path)
  end

  test "rejects runtimes without an executable" do
    assert {:error, %{category: :invalid_runtime}} =
             OMP.stream(
               %ReyCode.Provider.Runtime{module: OMP, status: :configured},
               request(),
               fn _ ->
                 :ok
               end
             )
  end

  test "reports unavailable executables before launching" do
    runtime = %ReyCode.Provider.Runtime{
      module: OMP,
      executable: Path.join(System.tmp_dir!(), "missing-omp-#{System.unique_integer()}"),
      config: RuntimeConfig.fresh().omp,
      workspace_policy: RuntimeConfig.fresh().workspace,
      status: :configured
    }

    assert {:error, %{category: :invalid_executable}} =
             OMP.stream(runtime, request(), fn _frame -> :ok end)
  end

  test "names the trust setting when the workspace is outside policy" do
    path =
      Path.join(System.tmp_dir!(), "rey-code-omp-policy-#{System.unique_integer([:positive])}")

    :ok = File.write(path, "#!/bin/sh\nexit 0\n")
    :ok = File.chmod(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    runtime = %ReyCode.Provider.Runtime{
      module: OMP,
      executable: path,
      config: RuntimeConfig.fresh().omp,
      workspace_policy: %RuntimeConfig.Workspace{roots: [System.tmp_dir!()]},
      status: :configured
    }

    outside = File.cwd!()
    request = %{request() | workspace: outside}

    assert {:error, %{category: :invalid_workspace, message: message}} =
             OMP.stream(runtime, request, fn _frame -> :ok end)

    assert message =~ "outside ReyCode's trusted roots"
    assert message =~ "REYCODE_WORKSPACE_ROOTS"
    assert message =~ outside
  end

  test "rejects prompts over the configured OMP limit" do
    path =
      Path.join(System.tmp_dir!(), "rey-code-omp-limit-#{System.unique_integer([:positive])}")

    :ok = File.write(path, "#!/bin/sh\nexit 0\n")
    :ok = File.chmod(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    config = RuntimeConfig.fresh(omp_max_prompt_bytes: 1)

    runtime = %ReyCode.Provider.Runtime{
      module: OMP,
      executable: path,
      config: config.omp,
      workspace_policy: config.workspace,
      status: :configured
    }

    assert {:error, %{category: :prompt_too_large}} =
             OMP.stream(runtime, request(), fn _frame -> :ok end)
  end

  test "reports an OMP discovery with no models" do
    path =
      Path.join(System.tmp_dir!(), "rey-code-omp-empty-#{System.unique_integer([:positive])}")

    :ok = File.write(path, "#!/bin/sh\nexit 0\n")
    :ok = File.chmod(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    config = RuntimeConfig.fresh()

    assert {:error, :no_models} =
             OMP.discover(executable: path, omp: config.omp, providers: config.providers)
  end

  test "reports a failed OMP model listing command" do
    path =
      Path.join(System.tmp_dir!(), "rey-code-omp-failed-#{System.unique_integer([:positive])}")

    :ok = File.write(path, "#!/bin/sh\nprintf '%s\\n' failed >&2\nexit 7\n")
    :ok = File.chmod(path, 0o700)
    on_exit(fn -> File.rm(path) end)

    config = RuntimeConfig.fresh()

    assert {:error, {:exit_status, 7, _diagnostics}} =
             OMP.discover(executable: path, omp: config.omp, providers: config.providers)
  end

  test "exposes the OMP provider behaviour" do
    Code.ensure_loaded!(OMP)
    assert function_exported?(OMP, :stream, 3)
    assert function_exported?(OMP, :discover, 1)
  end

  test "handles OMP protocol edge records and output limits" do
    assert Protocol.parse_line("not-json") == :ignore
    request = request()
    emit = fn _frame -> :ok end

    limited = Protocol.new(request, RuntimeConfig.fresh(omp_max_output_bytes: 2).omp)
    {:halt, limited} = Protocol.fold({:stdout, "123"}, limited, emit)
    assert {:error, %{category: :output_too_large}} = Protocol.finish(limited)

    state = Protocol.new(request, RuntimeConfig.fresh().omp)

    {:cont, state} =
      Protocol.fold(
        {:stdout,
         ~s({"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"x"}}\n)},
        state,
        emit
      )

    {:cont, state} = Protocol.fold({:stdout, ~s({"type":"unknown"}\n)}, state, emit)

    {:cont, state} =
      Protocol.fold({:stdout, ~s({"type":"error","error":42}\n)}, state, emit)

    {:cont, state} =
      Protocol.fold(
        {:stdout, ~s({"type":"response","success":false,"code":"bad"}\n)},
        state,
        emit
      )

    assert {:error, %{category: :provider_error}} = Protocol.finish(state)
  end
end
