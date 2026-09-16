defmodule ReyCode.LocalEngine.Bootstrap do
  @moduledoc "Transfers the validated engine configuration to a detached child through a private, one-use file."
  alias ReyCode.LocalEngine.Protocol
  @max_config_bytes 262_144

  def write(config) do
    directory = Path.join(ReyCode.Application.data_home(), ".engine")

    values =
      ReyCode.RuntimeConfig.declared_defaults()
      |> Map.merge(Map.new(Application.get_all_env(:rey_code)))
      |> Map.to_list()
      |> Keyword.delete(:engine_role)
      |> Keyword.put(:workspace_roots, config.workspace.roots)
      |> Keyword.put(:data_dir, ReyCode.Application.data_home())
      |> Keyword.put(:artifact_root, config.artifacts.root)
      |> Keyword.put(:event_path, configured_event_path())
      |> Keyword.put(:start_tui, false)

    bytes = :erlang.term_to_binary(values)
    path = Path.join(directory, "startup-#{System.unique_integer([:positive])}-#{System.pid()}")

    with true <- byte_size(bytes) <= @max_config_bytes,
         :ok <- File.mkdir_p(directory),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      _ -> {:error, :engine_configuration_transfer_failed}
    end
  end

  defp configured_event_path do
    case Application.get_env(:rey_code, :event_path) do
      nil -> nil
      path -> ReyCode.Paths.canonical_future(path)
    end
  end

  def restore do
    case System.get_env("REYCODE_ENGINE_CONFIG") do
      nil -> :ok
      path -> restore_file(path)
    end
  end

  defp restore_file(path) do
    Protocol.load_types()
    directory = Path.join(ReyCode.Application.data_home(), ".engine")

    with true <- Path.dirname(Path.expand(path)) == directory,
         {:ok, %{type: :regular, size: size}} when size <= @max_config_bytes <- File.lstat(path),
         {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :binary], fn io -> IO.binread(io, @max_config_bytes + 1) end),
         true <- byte_size(bytes) <= @max_config_bytes,
         {:ok, values} <- Protocol.decode(bytes),
         true <- Keyword.keyword?(values) do
      Enum.each(values, fn {key, value} -> Application.put_env(:rey_code, key, value) end)
      File.rm(path)
      System.delete_env("REYCODE_ENGINE_CONFIG")
      :ok
    else
      _ -> raise ArgumentError, "invalid shared engine startup configuration"
    end
  end
end
