defmodule ReyCode.TUI.TaskTimeTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Components.HUD

  @now ~U[2026-09-23 15:31:23Z]

  test "a running task shows elapsed time and a finished one its total" do
    running = %{status: :running, started_at: "2026-09-23T15:27:11Z", completed_at: nil}
    assert HUD.task_time(running, @now) == "TASK · running · 4m 12s"

    done = %{
      status: :terminal,
      started_at: "2026-09-23T14:00:00Z",
      completed_at: "2026-09-23T15:03:05Z"
    }

    assert HUD.task_time(done, @now) == "TASK · 1h 03m"

    quick = %{
      status: :terminal,
      started_at: "2026-09-23T15:31:00Z",
      completed_at: "2026-09-23T15:31:42Z"
    }

    assert HUD.task_time(quick, @now) == "TASK · 42s"
  end

  test "turns without durable timing show nothing" do
    assert HUD.task_time(%{status: :running, started_at: nil, completed_at: nil}, @now) == nil

    assert HUD.task_time(
             %{status: :terminal, started_at: "2026-09-23T15:31:00Z", completed_at: nil},
             @now
           ) == nil

    assert HUD.task_time(nil, @now) == nil
  end
end
