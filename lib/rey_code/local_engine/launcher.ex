defmodule ReyCode.LocalEngine.Launcher do
  @moduledoc "Attaches to, or starts, a detached engine using the current installation."
  alias ReyCode.LocalEngine.{Bootstrap, Protocol}
  @startup_timeout_ms 30_000
  @shutdown_timeout_ms 5_000

  def attach(path, identity, start? \\ true, config \\ nil) do
    case handshake(path, identity) do
      {:error, reason} when reason in [:enoent, :econnrefused] and start? ->
        start_engine(path, identity, config)

      {:error, {:engine_build_mismatch, version}} when start? ->
        with :ok <- replace_idle_engine(path, version),
             do: start_engine(path, identity, config)

      result ->
        result
    end
  end

  @doc "Checks startup compatibility and replaces an incompatible idle engine."
  @spec prepare(String.t(), map()) :: :ok | {:error, term()}
  def prepare(path, identity) do
    Protocol.load_types()

    case handshake(path, identity) do
      {:ok, socket, _snapshots} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        :ok

      {:error, {:engine_build_mismatch, version}} ->
        replace_idle_engine(path, version)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Waits a bounded interval for an explicitly stopped engine to release its socket."
  @spec await_stopped(String.t()) :: :ok | {:error, :engine_stop_timeout}
  def await_stopped(path),
    do: await_stopped(path, System.monotonic_time(:millisecond) + @shutdown_timeout_ms)

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

  defp start_engine(path, identity, config) do
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
  end

  defp replace_idle_engine(path, version) do
    with {:ok, socket} <- Protocol.connect(path) do
      result =
        with :ok <- Protocol.send(socket, {:control, :restart_if_idle}),
             do: Protocol.recv(socket)

      :gen_tcp.close(socket)

      case result do
        {:ok, :ok} -> await_stopped(path)
        {:ok, {:error, reason}} -> {:error, reason}
        _ -> {:error, {:engine_upgrade_required, version}}
      end
    end
  end

  defp await_stopped(path, deadline) do
    case Protocol.connect(path) do
      {:error, reason} when reason in [:enoent, :econnrefused] ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        continue_await_stopped(path, deadline)

      {:error, _reason} ->
        continue_await_stopped(path, deadline)
    end
  end

  defp continue_await_stopped(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :engine_stop_timeout}
    else
      receive do
      after
        50 -> await_stopped(path, deadline)
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
