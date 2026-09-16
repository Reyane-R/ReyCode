defmodule ReyCode.SharedEngineProcessTest do
  use ExUnit.Case, async: false
  alias ReyCode.LocalEngine.Protocol

  @tag timeout: 90_000
  test "separate OS clients auto-start one engine from different directories and leave it running" do
    base = Path.expand(".reycode/multi-#{System.unique_integer([:positive])}")
    data = Path.join(base, "data")
    a = Path.join(base, "project-a")
    b = Path.join(base, "project-b")
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    socket = Path.join([data, ".engine", "socket"])

    on_exit(fn ->
      case Protocol.connect(socket) do
        {:ok, connection} ->
          Protocol.send(connection, {:control, :stop})
          Protocol.recv(connection)
          :gen_tcp.close(connection)

        _ ->
          :ok
      end

      File.rm_rf!(base)
    end)

    {executable, args} = client_command()

    env = [
      {"REYCODE_DATA_DIR", data},
      {"REYCODE_LOG_DIR", Path.join(base, "logs")},
      {"REYCODE_ENGINE_ROLE", "client"},
      {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}
    ]

    tasks =
      Enum.map([a, b], fn cwd ->
        Task.async(fn ->
          System.cmd(executable, args,
            cd: cwd,
            env: env,
            stderr_to_stdout: true
          )
        end)
      end)

    outputs = Enum.map(tasks, &Task.await(&1, 45_000))

    for {output, status} <- outputs do
      assert status == 0, output
      assert output =~ "CLIENT_OK"
    end

    assert String.trim(File.read!(Path.join(a, "cwd.txt"))) == a
    assert String.trim(File.read!(Path.join(b, "cwd.txt"))) == b
    {:ok, connection} = Protocol.connect(socket)
    :ok = Protocol.send(connection, {:control, :status})
    assert {:ok, {:ok, %{protocol: 1}}} = Protocol.recv(connection)
    :gen_tcp.close(connection)
  end

  defp client_command do
    case System.get_env("REYCODE_TEST_RELEASE") do
      nil ->
        paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

        {System.find_executable("elixir"),
         Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", client_script()]}

      executable ->
        {executable, ["eval", client_script()]}
    end
  end

  defp client_script do
    """
    Application.load(:rey_code)
    Application.put_env(:rey_code, :engine_role, :client)
    Application.put_env(:rey_code, :data_dir, System.fetch_env!("REYCODE_DATA_DIR"))
    Application.put_env(:rey_code, :start_tui, false)
    Application.put_env(:rey_code, :provider_discovery, false)
    Application.put_env(:rey_code, :tui_update_check, false)
    Application.delete_env(:rey_code, :event_path)
    {:ok, _} = Application.ensure_all_started(:rey_code)
    {:ok, id} = ReyCode.Orchestration.Engine.ensure_workspace_session(".")
    :ok = ReyCode.Orchestration.Engine.run_owner_command(id, "pwd > cwd.txt")
    wait = fn
      _wait, 0 -> raise "Owner command did not finish"
      wait, remaining ->
        p = ReyCode.Orchestration.Engine.snapshot()
        if Enum.any?(p.messages, fn {_, m} -> m.session_id == id and String.starts_with?(m.body, "! pwd") end) do
          :ok
        else
          receive do
          after
            50 -> wait.(wait, remaining - 1)
          end
        end
    end
    :ok = wait.(wait, 100)
    {:error, report} = ReyCode.VerifiedChange.run(%{prompt: "Check this non-Git directory", workspace: File.cwd!(), commands: ["true"], timeout_ms: 5_000, check_timeout_ms: 1_000, max_repair_count: 0})
    encoded = Jason.encode!(report)
    false = String.contains?(encoded, "unsupported_engine_operation")
    false = String.contains?(encoded, "Shared engine result unavailable")
    IO.puts("CLIENT_OK")
    System.halt(0)
    """
  end
end
