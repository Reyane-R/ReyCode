defmodule ReyCode.LoggingTest do
  use ExUnit.Case, async: false

  alias ReyCode.{Logging, RuntimeConfig}

  setup do
    :logger.remove_handler(:rey_code_file)

    on_exit(fn ->
      :logger.remove_handler(:rey_code_file)
    end)

    :ok
  end

  test "does not install a file handler when file logging is disabled" do
    assert :ok = Logging.install!(RuntimeConfig.fresh(file_logging: false).logging)
    assert {:error, {:not_found, :rey_code_file}} = :logger.get_handler_config(:rey_code_file)
  end

  test "installs the file handler idempotently in an owner-only directory" do
    log_dir = Path.join(System.tmp_dir!(), "rey-code-logs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(log_dir) end)
    config = RuntimeConfig.fresh(file_logging: true, log_dir: log_dir).logging

    assert :ok = Logging.install!(config)
    assert :ok = Logging.install!(config)
    assert {:ok, %{id: :rey_code_file, level: :info}} = :logger.get_handler_config(:rey_code_file)
    assert File.dir?(log_dir)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(log_dir)
    assert Bitwise.band(mode, 0o777) == 0o700
  end
end
