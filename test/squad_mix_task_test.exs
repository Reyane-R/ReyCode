defmodule ReyCode.SquadMixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReyCode.Squad, as: SquadTask

  test "live runs require OpenCode provider and model" do
    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/--provider opencode/, fn ->
      Mix.Task.run("rey_code.squad", ["A theme"])
    end

    Mix.Task.reenable("rey_code.squad")

    assert_raise Mix.Error, ~r/--model provider\/model/, fn ->
      Mix.Task.run("rey_code.squad", ["--provider", "opencode", "A theme"])
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

    assert_raise Mix.Error, ~r/OpenCode model is unavailable/, fn ->
      Mix.Task.run(
        "rey_code.squad",
        ["--provider", "opencode", "--model", "provider/model", "A theme"]
      )
    end

    assert Application.get_env(:rey_code, :start_tui) == true
    assert Application.get_env(:rey_code, :squad_release_gate_human) == true
    assert Application.get_env(:rey_code, :squad_rework_budget) == 99
  end

  test "live JSON summaries identify the room workspace" do
    turn = %{
      id: "turn-1",
      room_id: "room-1",
      status: :completed,
      squad: %{
        workflow_version: 1,
        phase: :completed,
        cycle: 1,
        rework_count: 0,
        rework_budget: 3,
        artifacts: [],
        decisions: []
      }
    }

    workspace = Path.expand("test/fixtures/workspace")

    summary = SquadTask.summary(turn, workspace)
    assert summary.room_id == "room-1"
    assert summary.workspace == workspace
    assert Jason.decode!(Jason.encode!(summary))["workspace"] == workspace
  end

  test "renders live summaries at a focused formatter boundary" do
    turn = %{
      id: "turn-1",
      room_id: "room-1",
      status: :completed,
      squad: %{
        workflow_version: 1,
        phase: :completed,
        cycle: 2,
        rework_count: 1,
        rework_budget: 3,
        artifacts: [],
        decisions: []
      }
    }

    assert SquadTask.render(turn, "/workspace", :human) ==
             "Squad completed: completed, cycle 2, rework 1/3"

    decoded = turn |> SquadTask.render("/workspace", :json) |> Jason.decode!()
    assert decoded["workspace"] == "/workspace"
    assert decoded["status"] == "completed"
  end
end
