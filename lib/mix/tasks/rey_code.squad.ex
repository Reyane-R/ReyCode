defmodule Mix.Tasks.ReyCode.Squad do
  @shortdoc "Runs the fixed squad workflow with deterministic simulation options"

  @moduledoc """
  Runs a leader-supervised squad turn.

      mix rey_code.squad --seed 42 --jitter-ms 10 "Implement the change"

  Waiting is notification-driven: the command subscribes to Engine
  projection broadcasts and returns promptly on every durable terminal
  outcome, including cancelled turns. There is no implicit whole-run
  deadline — each provider invocation is bounded by the configured
  provider timeout — but an explicit monotonic cap can be set with
  `--timeout-ms`; expiry is reported as a timeout, distinct from any
  squad outcome.
  """

  use Mix.Task

  alias ReyCode.Orchestration.Squad
  alias ReyCode.Orchestration.Squad.MonteCarlo
  alias ReyCode.Provider.Catalog
  alias ReyCode.SquadWait

  @switches [
    seed: :integer,
    delay_ms: :integer,
    jitter_ms: :integer,
    failure_rate: :float,
    leader_rework_rounds: :integer,
    rework_budget: :integer,
    runs: :integer,
    provider: :string,
    model: :string,
    workspace: :string,
    json: :boolean,
    release: :string,
    timeout_ms: :integer
  ]

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")
    validate_release!(opts)
    runs = Keyword.get(opts, :runs, 1)

    if runs > 1 do
      run_monte_carlo(opts)
    else
      if args == [], do: Mix.raise("A theme is required")
      run_turn(opts, args)
    end
  end

  defp run_turn(opts, args) do
    config = live_config(opts, args)

    with_application_env(config.application_env, fn ->
      start_live_runtime(config)
      {room_id, workspace} = prepare_room(config)
      turn = execute_turn(room_id, workspace, config)
      Mix.shell().info(render(turn, workspace, config.format))

      case turn do
        %{status: :terminal, outcome: :completed} ->
          :ok

        %{status: :terminal, outcome: outcome} ->
          Mix.raise("Squad ended #{outcome}: theme not approved")

        _other ->
          Mix.raise("Squad did not finish")
      end
    end)
  end

  defp live_config(opts, args) do
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    if provider != "opencode",
      do: Mix.raise("Live squad runs require --provider opencode")

    if model in [nil, ""],
      do: Mix.raise("Live squad runs require --model provider/model")

    %{
      application_env: [
        start_tui: false,
        squad_release_gate_human: Keyword.get(opts, :release, "auto") == "wait",
        squad_rework_budget: Keyword.get(opts, :rework_budget, 3)
      ],
      format: if(opts[:json], do: :json, else: :human),
      model: model,
      release: Keyword.get(opts, :release, "auto"),
      timeout_ms: opts[:timeout_ms],
      theme: Enum.join(args, " "),
      workspace: opts[:workspace]
    }
  end

  defp validate_release!(opts) do
    case Keyword.get(opts, :release) do
      nil -> :ok
      mode when mode in ["auto", "wait"] -> :ok
      other -> Mix.raise("--release must be auto or wait, got: #{inspect(other)}")
    end
  end

  defp with_application_env(values, fun) do
    previous =
      Map.new(values, fn {key, _value} -> {key, Application.fetch_env(:rey_code, key)} end)

    try do
      Enum.each(values, fn {key, value} -> Application.put_env(:rey_code, key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:rey_code, key, value)
        {key, :error} -> Application.delete_env(:rey_code, key)
      end)
    end
  end

  defp start_live_runtime(config) do
    Mix.Task.run("app.start")

    case Catalog.resolve_when_ready(:opencode, config.model) do
      {:ok, _runtime} -> :ok
      {:error, reason} -> Mix.raise("OpenCode model is unavailable: #{reason}")
    end
  end

  defp prepare_room(config) do
    room_id = select_room(config.workspace)

    workspace =
      case ReyCode.snapshot() do
        %{rooms: %{^room_id => %{workspace: workspace}}} -> workspace
        _snapshot -> Mix.raise("Squad room #{room_id} is unavailable")
      end

    role_ids = Enum.map(Squad.roles(), & &1.id)

    case ReyCode.configure_squad_roles(room_id, role_ids, :opencode, config.model) do
      :ok -> {room_id, workspace}
      {:error, reason} -> Mix.raise("Could not configure squad roles: #{inspect(reason)}")
    end
  end

  defp select_room(nil) do
    case ReyCode.snapshot().room_order do
      [room_id | _rest] -> room_id
      [] -> Mix.raise("No squad room is available")
    end
  end

  defp select_room(workspace) do
    case ReyCode.create_room("Squad", workspace) do
      {:ok, room_id} -> room_id
      {:error, reason} -> Mix.raise("Could not create squad room: #{inspect(reason)}")
    end
  end

  defp execute_turn(room_id, workspace, config) do
    Mix.shell().info("Workspace: #{workspace}")

    case ReyCode.post_message(room_id, config.theme, :squad) do
      {:ok, turn_id} -> wait_for_turn(turn_id, config)
      {:error, reason} -> Mix.raise("Could not start squad turn: #{inspect(reason)}")
    end
  end

  defp wait_for_turn(turn_id, config) do
    case SquadWait.await(
           turn_id,
           timeout_ms: config.timeout_ms,
           on_phase: fn phase -> Mix.shell().info("[squad] #{phase}") end,
           on_gate_pending: fn turn -> resolve_human_gate(turn_id, turn) end
         ) do
      {:ok, turn} ->
        turn

      {:error, :timed_out} ->
        Mix.raise("Squad timed out after #{config.timeout_ms} ms")
    end
  end

  defp run_monte_carlo(opts) do
    summary =
      MonteCarlo.run(
        runs: Keyword.fetch!(opts, :runs),
        seed: Keyword.get(opts, :seed, 0),
        delay_ms: Keyword.get(opts, :delay_ms, 0),
        jitter_ms: Keyword.get(opts, :jitter_ms, 0),
        failure_rate: Keyword.get(opts, :failure_rate, 0.0),
        leader_rework_rounds: Keyword.get(opts, :leader_rework_rounds, 0)
      )

    if opts[:json] do
      Mix.shell().info(Jason.encode!(summary))
    else
      Mix.shell().info(
        "Monte Carlo: #{summary.runs} runs, #{summary.completed} completed, " <>
          "#{summary.failed} failed, max #{summary.max_steps} steps"
      )
    end
  end

  # A headless --release wait run has no TUI, so the terminal itself is the
  # owner console: print the pending gate, read a decision, submit it with the
  # review id so a stale answer can never resolve a newer gate.
  defp resolve_human_gate(turn_id, turn) do
    review = turn.squad.pending_review

    Mix.shell().info(
      "[squad] release gate awaiting the owner (leader says: " <>
        "#{review.recommendation.decision})"
    )

    decision = prompt_gate_decision()

    case ReyCode.resolve_gate(turn_id, review.id, decision, nil, []) do
      :ok ->
        Mix.shell().info("[squad] release gate resolved: #{decision}")

      {:error, reason} ->
        Mix.shell().info("[squad] could not resolve the gate (#{reason}); asking again")
        resolve_human_gate(turn_id, turn)
    end
  end

  defp prompt_gate_decision do
    case parse_gate_decision(Mix.shell().prompt("Release gate [a]pprove / [r]ework / a[b]ort:")) do
      {:ok, decision} ->
        decision

      :error ->
        Mix.shell().info("Unrecognized decision; answer a, r, or b.")
        prompt_gate_decision()
    end
  end

  @doc false
  @spec parse_gate_decision(String.t()) :: {:ok, :approve | :rework | :abort} | :error
  def parse_gate_decision(answer) do
    case answer |> String.trim() |> String.downcase() do
      choice when choice in ["a", "approve"] -> {:ok, :approve}
      choice when choice in ["r", "rework"] -> {:ok, :rework}
      choice when choice in ["b", "abort"] -> {:ok, :abort}
      _other -> :error
    end
  end

  @doc false
  def summary(turn, workspace) do
    %{
      turn_id: turn.id,
      room_id: turn.room_id,
      workspace: workspace,
      status: turn.outcome || turn.status,
      workflow_version: turn.squad.workflow_version,
      phase: turn.squad.phase,
      cycle: turn.squad.cycle,
      rework_count: turn.squad.rework_count,
      artifacts: Enum.reverse(turn.squad.artifacts),
      gates: Enum.reverse(turn.squad.resolutions)
    }
  end

  @doc false
  def render(turn, workspace, :json), do: turn |> summary(workspace) |> Jason.encode!()

  def render(turn, _workspace, :human) do
    result = turn.outcome || turn.status

    "Squad #{result}: #{turn.squad.phase}, cycle #{turn.squad.cycle}, " <>
      "rework #{turn.squad.rework_count}/#{turn.squad.rework_budget}"
  end
end
