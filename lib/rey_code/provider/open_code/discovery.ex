defmodule ReyCode.Provider.OpenCode.Discovery do
  @moduledoc "Discovers the OpenCode executable, version, credentials, and models."

  alias ReyCode.Provider.{Command, Runtime}
  alias ReyCode.Provider.OpenCode.Process
  alias ReyCode.Security.Environment

  require Logger

  @ansi ~r/\e\[[0-?]*[ -\/]*[@-~]/
  @model ~r/^[^\s\/]+\/.+$/
  @default_discovery_timeout_ms 5_000
  @default_discovery_output_bytes 256_000

  @spec discover(keyword()) :: {:ok, map()} | {:error, term()}
  def discover(opts \\ []) do
    executable = discovery_executable(opts)
    {executable, executable_identity} = executable_details(executable)
    environment_opts = Process.environment_opts()
    runner = discovery_runner(opts, environment_opts)
    command_opts = discovery_command_opts(opts, environment_opts)

    discover_provider(executable, executable_identity, runner, command_opts)
  end

  @spec parse_models(binary()) :: [String.t()]
  def parse_models(output) do
    output
    |> strip_ansi()
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@model, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec credential_count(binary()) :: non_neg_integer()
  def credential_count(output) do
    case Regex.run(~r/(\d+) credentials?/, strip_ansi(output), capture: :all_but_first) do
      [count] -> String.to_integer(count)
      _ -> 0
    end
  end

  defp discovery_executable(opts) do
    Keyword.get(opts, :executable) ||
      Application.get_env(:rey_code, :opencode_path) ||
      System.find_executable("opencode")
  end

  defp discovery_runner(opts, environment_opts) do
    Keyword.get_lazy(opts, :runner, fn ->
      fn executable, args, command_opts ->
        {wrapper, wrapped_args, env} = Environment.wrap(executable, args, environment_opts)
        Command.run(wrapper, wrapped_args, Keyword.put(command_opts, :env, env))
      end
    end)
  end

  defp discovery_command_opts(opts, environment_opts) do
    [
      env: Environment.launch_env(environment_opts),
      timeout_ms:
        Keyword.get(
          opts,
          :timeout_ms,
          Application.get_env(
            :rey_code,
            :provider_discovery_command_timeout_ms,
            @default_discovery_timeout_ms
          )
        ),
      max_output_bytes:
        Keyword.get(
          opts,
          :max_output_bytes,
          Application.get_env(
            :rey_code,
            :provider_discovery_output_bytes,
            @default_discovery_output_bytes
          )
        )
    ]
  end

  defp discover_provider(executable, executable_identity, runner, command_opts) do
    with executable when is_binary(executable) <- executable,
         {:ok, models} <- runner.(executable, ["models"], command_opts) do
      discovery_metadata(executable, executable_identity, models, runner, command_opts)
    else
      nil -> {:error, :missing_executable}
      {:error, reason} -> {:error, command_error(reason)}
    end
  end

  defp discovery_metadata(executable, executable_identity, models, runner, command_opts) do
    version_task =
      Task.async(fn -> safe_run(runner, executable, ["--version"], command_opts) end)

    auth_task =
      Task.async(fn -> safe_run(runner, executable, ["auth", "list"], command_opts) end)

    {:ok,
     %{
       executable: executable,
       executable_identity: executable_identity,
       version: discovery_version(version_task),
       credential_count: discovery_credential_count(auth_task),
       models: parse_models(models)
     }}
  end

  defp discovery_version(task) do
    case Task.await(task, :infinity) do
      {:ok, output} -> String.trim(strip_ansi(output))
      {:error, _reason} -> "unknown"
    end
  end

  defp discovery_credential_count(task) do
    case Task.await(task, :infinity) do
      {:ok, output} -> credential_count(output)
      {:error, _reason} -> 0
    end
  end

  defp safe_run(runner, executable, args, opts) do
    runner.(executable, args, opts)
  rescue
    error ->
      detail = Exception.message(error)
      Logger.warning("OpenCode metadata command failed: #{detail}")
      {:error, {:metadata_unavailable, detail}}
  catch
    kind, reason ->
      Logger.warning("OpenCode metadata command #{kind}: #{inspect(reason)}")
      {:error, {:metadata_unavailable, {kind, reason}}}
  end

  defp executable_details(nil), do: {nil, nil}

  defp executable_details(executable) do
    case Runtime.identify_executable(executable) do
      {:ok, identity} -> {identity.path, identity}
      {:error, _reason} -> {executable, nil}
    end
  end

  defp command_error(:timeout), do: :command_timeout

  defp command_error({:exit_status, status, output}) do
    output = output |> strip_ansi() |> String.trim()
    if output == "", do: "command exited with status #{status}", else: output
  end

  defp command_error({:output_limit_exceeded, limit}),
    do: "command output exceeded #{limit} bytes"

  defp command_error({:launch_failed, message}), do: message
  defp command_error(reason), do: reason

  defp strip_ansi(value), do: Regex.replace(@ansi, value, "")
end
