defmodule Mix.Tasks.ReyCode.Export do
  @moduledoc "Exports one durable ReyCode Session as deterministic Markdown or HTML."
  @shortdoc "Exports a durable ReyCode Session"

  use Mix.Task

  alias ReyCode.Orchestration.Engine
  alias ReyCode.SessionExport

  @switches [session: :string, format: :string, output: :string]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [], do: Mix.raise(usage())

    projection = Engine.snapshot()
    session = select_session(projection, opts[:session])
    format = parse_format(opts[:format] || "markdown")
    extension = if format == :html, do: ".html", else: ".md"
    output = opts[:output] || Path.join(File.cwd!(), session.id <> extension)

    case SessionExport.write(projection, session.id, output, format) do
      :ok -> Mix.shell().info("Exported #{session.id} to #{output}")
      {:error, reason} -> Mix.raise("Session export failed: #{inspect(reason)}")
    end
  end

  defp select_session(projection, nil) do
    case List.last(projection.session_order) do
      nil -> Mix.raise("No Sessions exist")
      session_id -> projection.sessions[session_id]
    end
  end

  defp select_session(projection, selector) do
    projection.session_order
    |> Enum.map(&projection.sessions[&1])
    |> Enum.find(fn session ->
      session.id == selector or String.starts_with?(session.id, selector) or
        session.title == selector
    end)
    |> case do
      nil -> Mix.raise("Session not found: #{selector}")
      session -> session
    end
  end

  defp parse_format("markdown"), do: :markdown
  defp parse_format("md"), do: :markdown
  defp parse_format("html"), do: :html
  defp parse_format(format), do: Mix.raise("Unsupported export format: #{format}")

  defp usage,
    do: "mix rey_code.export [--session ID|TITLE] [--format markdown|html] [--output PATH]"
end
