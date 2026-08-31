defmodule ReyCode.SquadMixTaskTest do
  alias ReyCode.SquadMixTaskTest.PromptReplies
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReyCode.Squad, as: SquadTask

  test "live runs require provider and model" do
    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/--provider PROVIDER/, fn ->
      Mix.Task.run("rey_code.squad", ["A theme"])
    end

    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/--model MODEL/, fn ->
      Mix.Task.run("rey_code.squad", ["--provider", "opencode", "A theme"])
    end
  end

  test "release flag accepts auto or wait and rejects anything else" do
    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/--release must be auto or wait/, fn ->
      Mix.Task.run("rey_code.squad", ["--release", "bogus", "A theme"])
    end

    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/--provider PROVIDER/, fn ->
      Mix.Task.run("rey_code.squad", ["--release", "wait", "A theme"])
    end
  end

  test "explicit Monte Carlo runs remain available without a live provider" do
    Mix.Task.reenable("rey_code.squad")

    output =
      capture_io(fn ->
        Mix.Task.run("rey_code.squad", ["--runs", "25", "--seed", "42"])
      end)

    assert output =~ "Monte Carlo: 25 runs"
  end

  test "parses headless release-gate decisions leniently" do
    assert SquadTask.parse_gate_decision("a\n") == {:ok, :approve}
    assert SquadTask.parse_gate_decision("  Approve  ") == {:ok, :approve}
    assert SquadTask.parse_gate_decision("R") == {:ok, :rework}
    assert SquadTask.parse_gate_decision("abort\n") == {:ok, :abort}
    assert SquadTask.parse_gate_decision("ship it") == :error
    assert SquadTask.parse_gate_decision("") == :error
  end

  test "live runs restore application configuration after startup failure" do
    keys = [:start_tui, :squad_release_gate_human, :squad_rework_budget]
    previous = Map.new(keys, &{&1, Application.fetch_env(:rey_code, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:rey_code, key, value)
        {key, :error} -> Application.delete_env(:rey_code, key)
      end)
    end)

    Application.put_env(:rey_code, :start_tui, true)
    Application.put_env(:rey_code, :squad_release_gate_human, true)
    Application.put_env(:rey_code, :squad_rework_budget, 99)
    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/Provider opencode model is unavailable/, fn ->
      Mix.Task.run(
        "rey_code.squad",
        ["--provider", "opencode", "--model", "provider/model", "A theme"]
      )
    end

    assert Application.get_env(:rey_code, :start_tui) == true
    assert Application.get_env(:rey_code, :squad_release_gate_human) == true
    assert Application.get_env(:rey_code, :squad_rework_budget) == 99
  end

  test "provider resolution accepts CLI, keyed API, and keyless local profiles" do
    config = ReyCode.RuntimeConfig.fresh()

    assert SquadTask.provider_id("opencode", config) == {:ok, :opencode}
    assert SquadTask.provider_id("deepseek", config) == {:ok, :deepseek}
    assert SquadTask.provider_id("ollama", config) == {:ok, :ollama}
    assert SquadTask.provider_id("unknown", config) == {:error, :unknown_provider}
  end

  test "live JSON summaries identify the room workspace" do
    turn = %{
      id: "turn-1",
      session_id: "room-1",
      status: :terminal,
      outcome: :completed,
      squad: %{
        workflow_version: 1,
        phase: :completed,
        cycle: 1,
        rework_count: 0,
        rework_budget: 3,
        artifacts: [],
        resolutions: []
      }
    }

    workspace = Path.expand("test/fixtures/workspace")

    summary = SquadTask.summary(turn, workspace)
    assert summary.session_id == "room-1"
    assert summary.workspace == workspace
    assert Jason.decode!(Jason.encode!(summary))["workspace"] == workspace
  end

  test "renders live summaries at a focused formatter boundary" do
    turn = %{
      id: "turn-1",
      session_id: "room-1",
      status: :terminal,
      outcome: :completed,
      squad: %{
        workflow_version: 1,
        phase: :completed,
        cycle: 2,
        rework_count: 1,
        rework_budget: 3,
        artifacts: [],
        resolutions: []
      }
    }

    assert SquadTask.render(turn, "/workspace", :human) ==
             "Squad completed: completed, cycle 2, rework 1/3"

    decoded = turn |> SquadTask.render("/workspace", :json) |> Jason.decode!()
    assert decoded["workspace"] == "/workspace"
    assert decoded["status"] == "completed"
  end

  test "renders monte carlo summaries as json" do
    Mix.Task.reenable("rey_code.squad")

    output =
      capture_io(fn ->
        Mix.Task.run("rey_code.squad", ["--runs", "2", "--seed", "3", "--json"])
      end)

    summary = Jason.decode!(output)
    assert summary["runs"] == 2
    assert summary["completed"] + summary["failed"] == 2
  end

  test "raises on unknown providers" do
    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/Unknown provider: bogus/, fn ->
      Mix.Task.run("rey_code.squad", ["--provider", "bogus", "--model", "m", "A theme"])
    end
  end

  test "runs a live simulator squad to completion" do
    workspace = live_workspace()
    Mix.Task.reenable("rey_code.squad")

    output =
      capture_io(fn ->
        Mix.Task.run("rey_code.squad", [
          "--provider",
          "simulator",
          "--model",
          "sim-test",
          "--workspace",
          workspace,
          "--timeout-ms",
          "120000",
          "Deliver",
          "the",
          "theme"
        ])
      end)

    assert output =~ "Squad completed"
  end

  test "raises when the simulator squad fails" do
    with_rebooted_app(:squad_simulator, failure_overrides(), fn ->
      workspace = live_workspace()
      Mix.Task.reenable("rey_code.squad")

      assert_raise Mix.Error, ~r/Squad ended failed/, fn ->
        Mix.Task.run("rey_code.squad", [
          "--provider",
          "simulator",
          "--model",
          "sim-test",
          "--workspace",
          workspace,
          "--timeout-ms",
          "120000",
          "A doomed theme"
        ])
      end
    end)
  end

  test "resolves the human release gate from the terminal" do
    with_rebooted_app(:squad_release_gate_human, true, fn ->
      workspace = live_workspace()
      Mix.Task.reenable("rey_code.squad")
      Mix.shell(ReyCode.SquadMixTaskTest.ScriptedShell)
      PromptReplies.install(["ship it", "approve"])

      try do
        output =
          capture_io(fn ->
            Mix.Task.run("rey_code.squad", [
              "--provider",
              "simulator",
              "--model",
              "sim-test",
              "--workspace",
              workspace,
              "--release",
              "wait",
              "--timeout-ms",
              "120000",
              "A gated theme"
            ])
          end)

        assert output =~ ~r/release gate awaiting the owner/
        assert output =~ ~r/Unrecognized decision/
        assert output =~ "release gate resolved: approve"
      after
        Mix.shell(Mix.Shell.IO)
      end
    end)
  end

  # The squad release-gate policy and simulator scenario are frozen into the
  # Engine and Catalog at boot, so overriding them requires the same reboot a
  # fresh CLI run performs.
  defp with_rebooted_app(key, value, fun) do
    previous = Application.get_env(:rey_code, key)

    on_exit(fn ->
      restore_env(key, previous)
      # The app may already be restarted by the inner after-block; syncing the
      # env there is enough because every later reboot reads it fresh.
    end)

    Application.put_env(:rey_code, key, value)
    restart_application()

    try do
      fun.()
    after
      restore_env(key, previous)
      restart_application()
    end
  end

  defp restore_env(_key, nil), do: Application.delete_env(:rey_code, :squad_simulator)
  defp restore_env(key, value), do: Application.put_env(:rey_code, key, value)

  defp failure_overrides do
    [seed: 0, delay_ms: 0, jitter_ms: 0, failure_rate: 1.0]
  end

  defp restart_application do
    Application.stop(:rey_code)
    {:ok, _apps} = ReyCode.Application.ensure_started_without_tui()
    :ok
  end

  defp live_workspace do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "rey_code_squad_task_ws_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    workspace
  end
end

defmodule ReyCode.SquadMixTaskTest.PromptReplies do
  use Agent

  def install(replies), do: Agent.start_link(fn -> replies end, name: __MODULE__)

  def next do
    Agent.get_and_update(__MODULE__, fn
      [reply | rest] -> {reply, rest}
      [] -> raise "no scripted prompt reply left"
    end)
  end
end

defmodule ReyCode.SquadMixTaskTest.ScriptedShell do
  @behaviour Mix.Shell
  alias ReyCode.SquadMixTaskTest.PromptReplies
  @impl true
  def info(message), do: IO.puts(message)
  @impl true
  def error(message), do: IO.puts(:stderr, message)
  @impl true
  def print_app, do: :ok
  @impl true
  def prompt(_message), do: PromptReplies.next()
  @impl true
  def cmd(command, opts \\ []), do: Mix.Shell.IO.cmd(command, opts)
  @impl true
  def yes?(message), do: Mix.Shell.IO.yes?(message)
  @impl true
  def yes?(message, _opts), do: yes?(message)
end
