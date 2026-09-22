defmodule ReyCode.CLI.Start do
  @moduledoc "Preflights shared-engine compatibility before release startup."
  alias ReyCode.LocalEngine.{Launcher, Protocol}

  def main(argv, halt \\ &System.halt/1)

  def main(argv, halt) when argv in [[], ["--update"]] do
    config = ReyCode.RuntimeConfig.load!()
    path = ReyCode.LocalEngine.socket_path()

    case Launcher.prepare(path, Protocol.identity(config)) do
      :ok ->
        :ok

      {:error, {:engine_upgrade_required, version}} when argv == ["--update"] ->
        stop_legacy_engine(path, version, halt)

      {:error, reason} ->
        fail(reason, halt)
    end
  end

  def main(_argv, halt) do
    IO.puts(:stderr, "Usage: reycode startup preflight")
    halt.(2)
  end

  defp stop_legacy_engine(path, version, halt) do
    IO.puts("Stopping legacy ReyCode engine #{version} for the explicit update")

    case ReyCode.LocalEngine.control(:stop) do
      :ok ->
        case Launcher.await_stopped(path) do
          :ok -> :ok
          {:error, reason} -> fail(reason, halt)
        end

      {:error, reason} ->
        fail(reason, halt)
    end
  end

  defp fail(:engine_busy, halt) do
    IO.puts(
      :stderr,
      "ReyCode cannot restart the shared engine while work is active. " <>
        "Wait for it to finish or run `reycode engine stop` when interruption is safe."
    )

    halt.(1)
  end

  defp fail({:engine_upgrade_required, version}, halt) do
    IO.puts(
      :stderr,
      "ReyCode engine #{version} cannot verify that restart is safe. " <>
        "Run `reycode engine stop` when interruption is safe, then launch ReyCode again."
    )

    halt.(1)
  end

  defp fail(reason, halt) do
    IO.puts(
      :stderr,
      "ReyCode could not prepare the shared engine: #{inspect(reason)}. " <>
        "If a stale engine is running, `reycode engine stop` releases it when interruption is safe."
    )

    halt.(1)
  end
end
