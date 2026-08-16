defmodule ReyCode.Provider.OpenCode.Process do
  @moduledoc "Launches the OpenCode CLI and streams raw output within a total deadline."

  alias ReyCode.Provider.Request
  alias ReyCode.Security.Environment

  @spec launch_args(Request.t()) :: [binary()]
  def launch_args(%Request{} = request) do
    [
      "run",
      "--format",
      "json",
      "--model",
      request.participant.model,
      "--dir",
      request.workspace
    ]
  end

  @spec open_stream(binary(), [binary()], binary(), binary()) :: Enumerable.t()
  def open_stream(executable, args, workspace, prompt) do
    {wrapper, wrapped_args, env} =
      Environment.wrap(executable, args, environment_opts())

    exile_stream([wrapper | wrapped_args],
      input: [prompt],
      stderr: :consume,
      ignore_epipe: true,
      exit_timeout: 1_000,
      max_chunk_size: 65_535,
      cd: workspace,
      env: env
    )
  end

  @spec collect(
          Enumerable.t(),
          (term(), term() -> {:cont, term()} | {:halt, term()}),
          term(),
          non_neg_integer()
        ) :: {:ok, term()} | {:error, map()}
  def collect(stream, reducer, acc, timeout) do
    task = collect_stream_task(stream, reducer, acc)
    await_stream_task(task, timeout)
  end

  @doc false
  @spec environment_opts() :: keyword()
  def environment_opts do
    [
      source: System.get_env(),
      additional_names: Application.get_env(:rey_code, :opencode_env_allowlist, []),
      cpu_seconds: Application.get_env(:rey_code, :opencode_cpu_seconds, 900),
      open_files: Application.get_env(:rey_code, :opencode_open_files, 1_024)
    ]
  end

  defp collect_stream_task(stream, reducer, acc) do
    Task.async(fn ->
      try do
        {:ok, Enum.reduce_while(stream, acc, reducer)}
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, reason -> {:error, Exception.format_banner(kind, reason)}
      end
    end)
  end

  defp await_stream_task(task, timeout) do
    case Task.yield(task, timeout) do
      {:ok, {:ok, final_state}} ->
        {:ok, final_state}

      {:ok, {:error, message}} ->
        {:error, error("launch_failed", message)}

      {:exit, reason} ->
        {:error, error("launch_failed", inspect(reason))}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, error("timeout", "OpenCode did not finish within #{timeout}ms")}
    end
  catch
    kind, reason ->
      {:error, error("launch_failed", Exception.format_banner(kind, reason))}
  end

  defp exile_stream(args, opts) do
    module = Exile
    module.stream(args, opts)
  end

  defp error(category, message) do
    %{"category" => category, "message" => message, "retryable" => false}
  end
end
