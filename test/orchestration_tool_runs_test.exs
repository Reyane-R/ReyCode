defmodule ReyCode.Orchestration.ToolRunsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.ToolRuns

  test "presentation-only diff previews never enter provider context" do
    run = %{
      status: :completed,
      result: %{
        "output" => "edited file",
        "truncated" => false,
        "metadata" => %{
          "path" => "/workspace/file.ex",
          "_tui_diff" => %{"lines" => ["-old", "+new"], "truncated" => false}
        }
      }
    }

    decoded = run |> ToolRuns.result_content() |> Jason.decode!()

    assert decoded["metadata"] == %{"path" => "/workspace/file.ex"}
    refute decoded["metadata"]["_tui_diff"]
  end
end
