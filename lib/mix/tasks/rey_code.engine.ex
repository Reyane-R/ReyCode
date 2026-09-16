defmodule Mix.Tasks.ReyCode.Engine do
  @moduledoc "Inspects or stops the shared engine without starting a client."
  @shortdoc "Shared engine status or stop"
  use Mix.Task

  @impl true
  def run([action]) when action in ["status", "stop"] do
    Mix.Task.run("app.config")
    operation = if action == "status", do: :status, else: :stop

    case ReyCode.LocalEngine.control(operation) do
      {:ok, identity} -> Mix.shell().info("ReyCode engine #{identity.version} is running")
      :ok -> Mix.shell().info("Engine stopping; connected terminals will disconnect")
      {:error, reason} -> Mix.raise("Engine unavailable: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix rey_code.engine status|stop")
end
