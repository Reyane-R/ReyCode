defmodule Mix.Tasks.ReyCode.Eval do
  @shortdoc "Auditions named task agents against the same task"

  @moduledoc """
  Runs one compare-style, headless model audition in a fresh room.

      mix rey_code.eval --agent Luna --agent Review --task "Run the focused tests"
      mix rey_code.eval --agent Luna --task "Summarize the diff" --json

  Names resolve exactly against task Participants in existing sessions. Their
  provider/model profiles are copied into the fresh room; missing or unavailable
  profiles become per-agent failure rows without aborting healthy candidates.
  """

  use Mix.Task

  alias ReyCode.ModelEval
  alias ReyCode.Orchestration.Engine

  @switches [
    agent: :keep,
    task: :string,
    workspace: :string,
    json: :boolean,
    timeout_ms: :integer
  ]
  @default_timeout_ms 600_000

  @impl true
  def run(argv) do
    options = parse!(argv)
    start_application_without_tui()
    report = ModelEval.run(options, Engine)
    format = if options.json?, do: :json, else: :human
    Mix.shell().info(ModelEval.render(report, format))
    ensure_success!(report)
  end

  @doc false
  @spec ensure_success!(ModelEval.report()) :: :ok | no_return()
  def ensure_success!(report) do
    unless ModelEval.success?(report) do
      failures = Enum.count(report.agents, &(&1.outcome != "completed"))
      Mix.raise("Model audition failed: #{failures} candidate(s) did not complete")
    end

    :ok
  end

  @doc false
  @spec parse!([String.t()]) :: ModelEval.options()
  def parse!(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    agents = opts |> Keyword.get_values(:agent) |> Enum.map(&String.trim/1)
    task = opts[:task]
    workspace = Path.expand(opts[:workspace] || File.cwd!())
    timeout_ms = opts[:timeout_ms] || @default_timeout_ms

    validate_shape!(invalid, args, agents, task)
    validate_unique_agents!(agents)
    validate_timeout!(timeout_ms)
    validate_workspace!(workspace)

    %{
      agents: agents,
      task: task,
      workspace: workspace,
      json?: !!opts[:json],
      timeout_ms: timeout_ms
    }
  end

  defp validate_shape!(invalid, args, agents, task) do
    if invalid != [] or args != [] or agents == [] or Enum.any?(agents, &(&1 == "")) or
         not is_binary(task) or String.trim(task) == "" do
      usage!()
    end
  end

  defp validate_unique_agents!(agents) do
    if length(agents) != length(Enum.uniq(agents)), do: Mix.raise("Agent names must be unique")
  end

  defp validate_timeout!(timeout_ms) do
    if not is_integer(timeout_ms) or timeout_ms <= 0,
      do: Mix.raise("--timeout-ms must be positive")
  end

  defp validate_workspace!(workspace) do
    unless File.dir?(workspace), do: Mix.raise("Workspace is not a directory: #{workspace}")
  end

  defp start_application_without_tui do
    previous = Application.get_env(:rey_code, :start_tui, :not_configured)
    Application.put_env(:rey_code, :start_tui, false)

    try do
      Mix.Task.run("app.start")
    after
      restore_tui_config(previous)
    end
  end

  defp restore_tui_config(:not_configured), do: Application.delete_env(:rey_code, :start_tui)
  defp restore_tui_config(value), do: Application.put_env(:rey_code, :start_tui, value)

  @spec usage!() :: no_return()
  defp usage! do
    Mix.raise(
      "Usage: mix rey_code.eval --agent NAME [--agent NAME ...] --task TEXT " <>
        "[--workspace DIR] [--json] [--timeout-ms N]"
    )
  end
end
