defmodule ReyCode.CLI.Desktop do
  @moduledoc "`reycode desktop`: serves the web view, opens the browser, and runs until stopped."

  alias ReyCode.{Application, Web}

  @spec main([String.t()], (non_neg_integer() -> no_return())) :: no_return()
  def main(argv, halt \\ &System.halt/1) do
    case parse(argv) do
      {:ok, port} ->
        serve(port, halt)

      {:error, :usage} ->
        IO.puts(:stderr, "Usage: reycode desktop [--port N]")
        halt.(2)
    end
  end

  defp serve(port, halt) do
    with {:ok, _apps} <- Application.ensure_started_without_tui(),
         {:ok, pid} <- Web.start(port) do
      url = Web.url(port)
      IO.puts("ReyCode Desktop: #{url}  (Ctrl+C to stop)")
      _ = Web.open_browser(url)

      # Runs exactly as long as the endpoint does.
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> halt.(1)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, Web.describe_error(reason, port))
        halt.(1)
    end
  end

  @doc false
  @spec parse([String.t()]) :: {:ok, pos_integer()} | {:error, :usage}
  def parse(argv) do
    case OptionParser.parse(argv, strict: [port: :integer]) do
      {opts, [], []} -> port(Keyword.get(opts, :port, Web.default_port()))
      _invalid -> {:error, :usage}
    end
  end

  defp port(port) when port in 1..65_535, do: {:ok, port}
  defp port(_port), do: {:error, :usage}
end
