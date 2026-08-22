defmodule ReyCode.Tool.Bash do
  @moduledoc """
  Executes an approved shell command against the host under a minimal
  allowlisted environment.

  Bash is explicit host execution, not a filesystem sandbox: every run shows
  the exact command for owner approval before anything executes. On timeout
  the whole process tree is torn down — the environment wrapper traps TERM
  and kills its process group, and the executor escalates to SIGKILL. Stdout
  and stderr are captured separately under byte caps, and every result reports
  the exit code, wall time, timeout, and truncation state.
  """

  alias ReyCode.Provider.TextBuffer
  alias ReyCode.Security.{Environment, Workspace}
  alias ReyCode.Tool.{Request, Result, Support}

  @behaviour ReyCode.Tool

  @chunk_bytes 65_535
  @kill_grace_ms 5_000
  @reap_grace_ms 5_000

  defp timeout_ms, do: Application.get_env(:rey_code, :tool_bash_timeout_ms, 30_000)
  defp max_output_bytes, do: Application.get_env(:rey_code, :tool_bash_max_output_bytes, 256_000)
  defp max_error_bytes, do: Application.get_env(:rey_code, :tool_bash_max_error_bytes, 64_000)

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, _opts) do
    command = Support.arg(arguments, :command)

    case command do
      command when command in [nil, ""] ->
        Result.error(:missing_command)

      command ->
        execute(command, cwd(arguments, workspace))
    end
  end

  defp cwd(arguments, workspace) do
    case Workspace.contained?(Support.arg(arguments, :cwd, workspace)) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> Support.arg(arguments, :cwd, workspace)
    end
  end

  defp execute(command, cwd) do
    {wrapper, wrapped_args, env} =
      Environment.wrap("bash", ["-c", command], environment_opts())

    started_at = System.monotonic_time(:millisecond)

    with {:ok, proc} <- start(wrapper, wrapped_args, env, cwd),
         {:ok, capture, status, timed_out?} <- collect(proc, timeout_ms()) do
      wall_ms = System.monotonic_time(:millisecond) - started_at
      build_result(capture, status, timed_out?, wall_ms)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp environment_opts do
    [
      source: System.get_env(),
      additional_names: Application.get_env(:rey_code, :tool_bash_env_allowlist, []),
      cpu_seconds: Application.get_env(:rey_code, :tool_bash_cpu_seconds, 120),
      open_files: Application.get_env(:rey_code, :tool_bash_open_files, 1_024)
    ]
  end

  defp start(wrapper, wrapped_args, env, cwd) do
    case Exile.Process.start_link([wrapper | wrapped_args],
           cd: cwd,
           env: env,
           stderr: :consume
         ) do
      {:ok, proc} ->
        {:ok, proc}

      {:error, reason} ->
        {:error, "bash failed to start: #{inspect(reason)}"}
    end
  end

  # Streams stdout/stderr through a reader task that owns both pipes, while
  # this process stays the Exile process owner so it alone controls
  # termination. Stdin is left to Exile's exit sequence; commands that wait
  # on it simply run until the timeout tears them down.
  defp collect(proc, timeout_ms) do
    reader = Task.async(fn -> own_and_drain(proc) end)

    try do
      capture = Task.await(reader, timeout_ms)
      {:ok, capture, exit_status(Exile.Process.await_exit(proc, @reap_grace_ms)), false}
    catch
      :exit, _reason ->
        {capture, status} = terminate_tree(proc, reader)
        {:ok, capture, status || 137, true}
    end
  end

  defp own_and_drain(proc) do
    :ok = Exile.Process.change_pipe_owner(proc, :stdout, self())
    :ok = Exile.Process.change_pipe_owner(proc, :stderr, self())
    drain(proc)
  end

  defp exit_status({:ok, status}) when is_integer(status), do: status
  defp exit_status(status) when is_integer(status), do: status

  # SIGTERM reaches the wrapper, whose trap kills the entire process group;
  # awaiting exit lets Exile escalate to SIGKILL and reap the status.
  defp terminate_tree(proc, reader) do
    Exile.Process.kill(proc, :sigterm)

    status =
      try do
        exit_status(Exile.Process.await_exit(proc, @kill_grace_ms))
      catch
        :exit, _reason -> nil
      end

    {await_capture(reader), status}
  end

  defp await_capture(reader) do
    Task.await(reader, @kill_grace_ms)
  catch
    :exit, _reason ->
      _ = Task.shutdown(reader, :brutal_kill)
      %{new_capture() | truncated?: true}
  end

  defp drain(proc) do
    drain(proc, new_capture())
  end

  defp drain(proc, capture) do
    case Exile.Process.read_any(proc, @chunk_bytes) do
      {:ok, {:stdout, data}} -> drain(proc, append(capture, :stdout, data))
      {:ok, {:stderr, data}} -> drain(proc, append(capture, :stderr, data))
      :eof -> capture
      {:error, _reason} -> %{capture | broken?: true}
    end
  end

  defp new_capture,
    do: %{stdout: {[], 0}, stderr: {[], 0}, truncated?: false, broken?: false}

  defp append(capture, key, data) do
    cap = if key == :stdout, do: max_output_bytes(), else: max_error_bytes()
    {parts, size} = Map.fetch!(capture, key)

    if size >= cap do
      %{capture | truncated?: true}
    else
      kept = TextBuffer.truncate_utf8(data, cap - size)

      capture =
        if byte_size(kept) < byte_size(data), do: %{capture | truncated?: true}, else: capture

      %{capture | key => {[kept | parts], size + byte_size(kept)}}
    end
  end

  defp build_result(capture, status, timed_out?, wall_ms) do
    output = render(capture.stdout, max_output_bytes(), capture.truncated?)
    stderr = render(capture.stderr, max_error_bytes(), false)

    metadata =
      %{
        "exit_code" => status,
        "wall_time_ms" => wall_ms,
        "timed_out" => timed_out?,
        "broken_pipe" => capture.broken?
      }

    cond do
      timed_out? ->
        Result.error(
          %{"exit_code" => status, "output" => output, "stderr" => stderr, "reason" => "timeout"},
          metadata: metadata,
          truncated: capture.truncated?
        )

      status == 0 ->
        Result.ok(output, metadata: metadata, truncated: capture.truncated?)

      true ->
        Result.error(
          %{"exit_code" => status, "output" => output, "stderr" => stderr},
          metadata: metadata,
          truncated: capture.truncated?
        )
    end
  end

  defp render({parts, size}, cap, truncated?) do
    output = parts |> Enum.reverse() |> IO.iodata_to_binary()

    if truncated? and size >= cap do
      output <> "\n[output truncated at #{cap} bytes]"
    else
      output
    end
  end
end
