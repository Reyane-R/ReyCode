defmodule ReyCode.LocalEngine.Launcher do
  @moduledoc "Attaches to, or starts, a detached engine using the current installation."
  alias ReyCode.LocalEngine.{Bootstrap, Protocol}
  @startup_timeout_ms 30_000

  def attach(path, identity, start? \\ true, config \\ nil) do
    case handshake(path, identity) do
      {:error, reason} when reason in [:enoent, :econnrefused] and start? ->
        with {:ok, manifest} <- Bootstrap.write(config) do
          try do
            with :ok <- launch(manifest),
                 do:
                   await(
                     path,
                     identity,
                     System.monotonic_time(:millisecond) + @startup_timeout_ms
                   )
          after
            File.rm(manifest)
          end
        end

      result ->
        result
    end
  end

  defp handshake(path, identity) do
    with {:ok, socket} <- Protocol.connect(path) do
      result = with :ok <- Protocol.send(socket, {:hello, identity}), do: Protocol.recv(socket)

      case result do
        {:ok, {:ok, snapshots}} ->
          {:ok, socket, snapshots}

        {:ok, {:error, reason}} ->
          :gen_tcp.close(socket)
          {:error, reason}

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, reason}

        _ ->
          :gen_tcp.close(socket)
          {:error, :invalid_engine_handshake}
      end
    end
  end

  defp await(path, identity, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :engine_start_timeout}
    else
      case handshake(path, identity) do
        {:error, reason} when reason in [:enoent, :econnrefused] ->
          receive do
          after
            50 -> await(path, identity, deadline)
          end

        result ->
          result
      end
    end
  end

  defp launch(manifest) do
    {executable, args, cwd} = launch_command()

    env = [
      {~c"REYCODE_ENGINE_ROLE", ~c"engine"},
      {~c"REYCODE_ENGINE_CONFIG", to_charlist(manifest)},
      {~c"REYCODE_DATA_DIR", to_charlist(ReyCode.Application.data_home())}
    ]

    env =
      if System.get_env("RELEASE_ROOT"),
        do: env,
        else: [
          {~c"MIX_ENV",
           Application.app_dir(:rey_code)
           |> Path.join("../..")
           |> Path.expand()
           |> Path.basename()
           |> to_charlist()}
          | env
        ]

    port =
      Port.open({:spawn_executable, to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, Enum.map(args, &to_charlist/1)},
        {:env, env},
        {:cd, to_charlist(cwd)}
      ])

    await_launcher(port, System.monotonic_time(:millisecond) + 5_000, 16_384)
  rescue
    _ -> {:error, :engine_launch_failed}
  end

  defp launch_command do
    case System.get_env("RELEASE_ROOT") do
      nil ->
        root = Application.app_dir(:rey_code) |> Path.join("../../../..") |> Path.expand()

        {System.find_executable("elixir"),
         ["--erl", "-detached", "-S", "mix", "run", "--no-halt"], root}

      root ->
        {Path.join(root, "bin/rey_code"), ["daemon"], root}
    end
  end

  defp await_launcher(port, deadline, remaining_bytes) do
    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _status}} ->
        {:error, :engine_launch_failed}

      {^port, {:data, bytes}} when byte_size(bytes) <= remaining_bytes ->
        await_launcher(port, deadline, remaining_bytes - byte_size(bytes))

      {^port, {:data, _bytes}} ->
        Port.close(port)
        {:error, :engine_launch_output_limit}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, :engine_launch_timeout}
    end
  end
end
