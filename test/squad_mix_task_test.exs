defmodule ReyCode.SquadMixTaskTest do
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
end
