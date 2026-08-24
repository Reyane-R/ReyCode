defmodule ReyCode.Logging do
  @moduledoc false

  alias ReyCode.RuntimeConfig

  @max_bytes 10 * 1024 * 1024
  @max_files 5

  @spec install!(RuntimeConfig.t()) :: :ok
  def install!(%RuntimeConfig{} = config) do
    if config.file_logging do
      log_dir = config.log_dir

      log_path = Path.join(log_dir, "rey_code.log")
      File.mkdir_p!(log_dir)
      File.chmod!(log_dir, 0o700)

      config = %{
        level: :info,
        config: %{
          type: {:file, String.to_charlist(log_path)},
          max_no_bytes: @max_bytes,
          max_no_files: @max_files,
          compress_on_rotate: true,
          filesync_repeat_interval: 5_000
        }
      }

      case :logger.add_handler(:rey_code_file, :logger_std_h, config) do
        :ok -> :ok
        {:error, {:already_exist, :rey_code_file}} -> :ok
        {:error, reason} -> raise "could not install file logger: #{inspect(reason)}"
      end

      if File.exists?(log_path), do: File.chmod!(log_path, 0o600)
    end

    :ok
  end
end
