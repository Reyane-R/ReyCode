defmodule ReyCode.Provider.Command do
  @moduledoc "Runs an executable directly with bounded output and a total deadline."

  @default_timeout_ms 10_000
  @default_max_output_bytes 256_000

  @type reason ::
          :timeout
          | {:exit_status, non_neg_integer(), binary()}
          | {:output_limit_exceeded, non_neg_integer()}
          | {:launch_failed, binary()}

  @spec run(binary(), [binary()], keyword()) :: {:ok, binary()} | {:error, reason()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args,
      env: normalize_env(Keyword.get(opts, :env, [{"NO_COLOR", "1"}]))
    ]

    port_opts = maybe_put(port_opts, :cd, Keyword.get(opts, :cd))

    try do
      port = Port.open({:spawn_executable, executable}, port_opts)
      os_pid = get_os_pid(port)

      try do
        collect(port, deadline, max_output_bytes, [], 0)
      after
        close(port, os_pid)
      end
    rescue
      error -> {:error, {:launch_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:launch_failed, Exception.format_banner(kind, reason)}}
    end
  end

  defp collect(port, deadline, max_output_bytes, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          next_size = size + byte_size(data)

          if next_size > max_output_bytes do
            {:error, {:output_limit_exceeded, max_output_bytes}}
          else
            collect(port, deadline, max_output_bytes, [data | chunks], next_size)
          end

        {^port, {:exit_status, status}} ->
          output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

          if status == 0 do
            {:ok, output}
          else
            {:error, {:exit_status, status, output}}
          end
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  @spec get_os_pid(port()) :: non_neg_integer() | nil
  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  @spec close(port(), non_neg_integer() | nil) :: :ok
  defp close(port, os_pid) do
    if Port.info(port) != nil do
      terminate_process_group(os_pid)
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec terminate_process_group(non_neg_integer() | nil) :: :ok
  defp terminate_process_group(nil), do: :ok

  defp terminate_process_group(os_pid) do
    send_signal(["-TERM", "-#{os_pid}"])
    Process.sleep(150)
    send_signal(["-KILL", "-#{os_pid}"])
    send_signal(["-KILL", "#{os_pid}"])

    :ok
  end

  defp send_signal(args) do
    _ = System.cmd("/bin/kill", args, stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_env(env) do
    Enum.map(env, fn {key, value} -> {as_charlist(key), as_charlist(value)} end)
  end

  defp as_charlist(value) when is_binary(value), do: String.to_charlist(value)
  defp as_charlist(value) when is_list(value), do: value
end
