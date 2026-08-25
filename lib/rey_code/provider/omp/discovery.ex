defmodule ReyCode.Provider.OMP.Discovery do
  @moduledoc "Discovers the OMP executable, version, and available models."

  alias ReyCode.Provider.{Command, Runtime}
  alias ReyCode.Provider.OMP.Process
  alias ReyCode.RuntimeConfig
  alias ReyCode.Security.Environment

  @spec discover(keyword()) :: {:ok, map()} | {:error, term()}
  def discover(opts \\ []) do
    defaults = RuntimeConfig.fresh()
    policy = Keyword.get(opts, :omp, defaults.omp)
    providers = Keyword.get(opts, :providers, defaults.providers)
    executable = Keyword.get(opts, :executable) || policy.path || System.find_executable("omp")
    {executable, executable_identity} = executable_details(executable)

    if is_binary(executable) do
      environment_opts = Process.environment_opts(policy)

      command_opts = [
        timeout_ms: Keyword.get(opts, :timeout_ms, providers.discovery_command_timeout_ms),
        max_output_bytes: Keyword.get(opts, :max_output_bytes, policy.discovery_output_bytes)
      ]

      with {:ok, output} <- query_models(executable, environment_opts, command_opts),
           models when models != [] <- parse_models(output) do
        {:ok,
         %{
           executable: executable,
           executable_identity: executable_identity,
           version: version(executable, environment_opts, command_opts),
           credential_count: 0,
           models: models
         }}
      else
        [] -> {:error, :no_models}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_executable}
    end
  end

  @spec parse_models(binary()) :: [String.t()]
  def parse_models(output) do
    (parse_rpc_models(output) ++ parse_table_models(output))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_rpc_models(output) do
    {models, pending} =
      output
      |> String.split(~r/\R/, trim: true)
      |> Enum.reduce({[], ""}, &parse_record_line/2)

    case decode_model_record(pending) do
      {:ok, record} -> response_models(record) ++ models
      :ignore -> models
    end
  end

  defp parse_table_models(output) do
    {_provider, models} =
      output
      |> String.split(~r/\R/, trim: true)
      |> Enum.reduce({nil, []}, &parse_table_line/2)

    models
  end

  defp parse_table_line(line, {provider, models}) do
    case Regex.run(~r/^\s*([^\s(]+)\s+\(\d+\)\s*$/, line, capture: :all_but_first) do
      [name] -> {name, models}
      _other -> parse_table_row(line, provider, models)
    end
  end

  defp parse_table_row(_line, nil, models), do: {nil, models}

  defp parse_table_row(line, provider, models) do
    case Regex.run(~r/^\s*│\s*([^\s│]+)\s*│/, line, capture: :all_but_first) do
      [model] when model != "model" -> {provider, ["#{provider}/#{model}" | models]}
      _other -> {provider, models}
    end
  end

  defp parse_record_line(line, {models, pending}) do
    candidate = if pending == "", do: String.trim(line), else: pending <> String.trim(line)

    case decode_model_record(candidate) do
      {:ok, record} -> {response_models(record) ++ models, ""}
      :ignore -> {models, candidate}
    end
  end

  defp decode_model_record(""), do: :ignore

  defp decode_model_record(line) do
    case Jason.decode(line) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> :ignore
    end
  end

  defp response_models(
         %{
           "type" => "response",
           "command" => "get_available_models",
           "success" => true
         } = record
       ) do
    record
    |> get_in(["data", "models"])
    |> List.wrap()
    |> Enum.flat_map(&model_id/1)
  end

  defp response_models(_record), do: []

  defp model_id(%{"provider" => provider, "id" => id})
       when is_binary(provider) and provider != "" and is_binary(id) and id != "" do
    ["#{provider}/#{id}"]
  end

  defp model_id(%{"id" => id}) when is_binary(id) and id != "", do: [id]
  defp model_id(id) when is_binary(id) and id != "", do: [id]
  defp model_id(_other), do: []

  defp query_models(executable, environment_opts, command_opts) do
    {wrapper, args, env} = Environment.wrap(executable, ["models"], environment_opts)

    case Command.run(wrapper, args, Keyword.merge(command_opts, env: env)) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp version(executable, environment_opts, command_opts) do
    {wrapper, args, env} = Environment.wrap(executable, ["--version"], environment_opts)

    case Command.run(wrapper, args, Keyword.merge(command_opts, env: env)) do
      {:ok, output} -> String.trim(output)
      {:error, _reason} -> "unknown"
    end
  end

  defp executable_details(nil), do: {nil, nil}

  defp executable_details(executable) do
    case Runtime.identify_executable(executable) do
      {:ok, identity} -> {identity.path, identity}
      {:error, _reason} -> {executable, nil}
    end
  end
end
