defmodule ReyCode.Orchestration.Engine.OptionsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine.Options

  test "normalizes finite, zero queue, and infinite execution limits" do
    assert Options.execution_limits(
             global_concurrency: 3,
             workspace_concurrency: :infinity,
             global_queue_limit: 0,
             workspace_queue_limit: 4
           ) == %{
             global_concurrency: 3,
             workspace_concurrency: :infinity,
             global_queue_limit: 0,
             workspace_queue_limit: 4
           }
  end

  test "rejects invalid concurrency and queue limits with the option name" do
    assert_raise ArgumentError, "invalid global_concurrency: 0", fn ->
      Options.execution_limits(global_concurrency: 0)
    end

    assert_raise ArgumentError, "invalid workspace_queue_limit: -1", fn ->
      Options.execution_limits(workspace_queue_limit: -1)
    end
  end
end
