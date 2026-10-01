defmodule Mix.Tasks.ReyCode.Web do
  @shortdoc "Serves the read-only web view (ReyCode Desktop) on 127.0.0.1"

  @moduledoc """
  Development entry point for `reycode desktop`: starts ReyCode without the
  TUI, serves the read-only web view, and opens it in the browser.

      mix rey_code.web            # http://127.0.0.1:4747
      mix rey_code.web --port 5000
  """

  use Mix.Task

  alias ReyCode.CLI.Desktop

  @impl true
  def run(args), do: Desktop.main(args)
end
