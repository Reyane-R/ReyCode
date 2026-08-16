defmodule ReyCode.Logging do
  @moduledoc false

  @max_bytes 10 * 1024 * 1024
  @max_files 5

  def install! do
    if Application.get_env(:rey_code, :file_logging, false) do
      log_dir =
        Application.get_env(:rey_code, :log_dir, Path.expand("~/Library/Logs/ReyCode"))

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
