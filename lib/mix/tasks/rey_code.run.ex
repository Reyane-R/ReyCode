defmodule Mix.Tasks.ReyCode.Run do
  @shortdoc "Runs one Primary Assistant prompt without the TUI"

  @moduledoc """
  Runs one bounded prompt from an option, positional arguments, or piped stdin.

      mix rey_code.run -p "Summarize this workspace"
      printf 'Run the focused tests' | mix rey_code.run
      mix rey_code.run "Explain the current diff" --json
  """

  use Mix.Task

  alias ReyCode.CLI.Run

  @impl true
  def run(argv) do
    case Run.execute(argv) do
      {:ok, output} -> Mix.shell().info(output)
      {:error, message} -> Mix.raise(message)
    end
  end
end
