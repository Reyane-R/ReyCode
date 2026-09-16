defmodule ReyCode.CLI.Engine do
  @moduledoc "Explicit shared-engine lifecycle commands for the installed launcher."
  def main([action]) when action in ["status", "stop"] do
    operation = if action == "status", do: :status, else: :stop

    case ReyCode.LocalEngine.control(operation) do
      {:ok, identity} ->
        IO.puts("ReyCode engine #{identity.version} is running")

      :ok ->
        IO.puts("Engine stopping; connected terminals will disconnect")

      {:error, reason} ->
        IO.puts(:stderr, "Engine unavailable: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "Usage: reycode engine status|stop")
    System.halt(2)
  end
end
