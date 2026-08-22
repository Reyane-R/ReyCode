defmodule ReyCode.Tool.Bash do
  @moduledoc "Executes a shell command within the workspace under a minimal, sandboxed environment."
  @behaviour ReyCode.Tool

  alias ReyCode.Security.{Environment, Workspace}
  alias ReyCode.Tool.{Request, Result, Support}

  @timeout_ms Application.compile_env(:rey_code, :tool_bash_timeout_ms, 30_000)

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, _opts) do
    command = Support.arg(arguments, :command)

    case command do
      nil ->
        Result.error(:missing_command)

      "" ->
        Result.error(:missing_command)

      command ->
        cwd = Support.arg(arguments, :cwd, workspace)
        run_command(command, cwd)
    end
  end

  defp run_command(command, cwd) do
    {wrapper, wrapped_args, env} =
      Environment.wrap("bash", ["-c", command], environment_opts())

    cwd =
      case Workspace.contained?(cwd) do
        {:ok, canonical} -> canonical
        {:error, _reason} -> cwd
      end

    stream = exile_stream([wrapper | wrapped_args], env, cwd)

    case collect(stream, @timeout_ms) do
      {:ok, %{stdout: stdout, exit_code: 0}} ->
        Result.ok(stdout)

      {:ok, %{stdout: stdout, exit_code: code}} ->
        Result.error(%{exit_code: code, output: stdout})

      {:error, message} ->
        Result.error(message)
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

  defp exile_stream(args, env, cwd) do
    Exile.stream(args,
      input: [],
      stderr: :consume,
      ignore_epipe: true,
      exit_timeout: 1_000,
      max_chunk_size: 65_535,
      cd: cwd,
      env: env
    )
  end

  defp collect(stream, timeout) do
    task = Task.async(fn -> reduce_stream(stream) end)

    case Task.yield(task, timeout) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "bash exited: #{inspect(reason)}"}
      nil -> {:error, "bash timed out after #{timeout}ms"}
    end
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp reduce_stream(stream) do
    acc = %{stdout: [], exit_code: 0}

    result =
      Enum.reduce_while(stream, acc, fn
        {:stdout, data}, state ->
          {:cont, %{state | stdout: [data | state.stdout]}}

        {:stderr, _data}, state ->
          {:cont, state}

        {:exit, {:status, code}}, state ->
          {:halt, %{state | exit_code: code}}

        {:exit, _other}, state ->
          {:halt, %{state | exit_code: 1}}
      end)

    {:ok, %{result | stdout: IO.iodata_to_binary(Enum.reverse(result.stdout))}}
  end
end
