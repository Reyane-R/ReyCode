defmodule ReyCode.Tool.EvalTest do
  use ExUnit.Case, async: true

  alias ReyCode.EvalHub
  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  test "persists Python state across evaluations" do
    workspace = System.tmp_dir!()
    name = "python-#{System.unique_integer([:positive])}"

    request = fn args ->
      Request.new(tool: "eval", arguments: args, workspace: workspace, roots: [workspace])
    end

    start_request = request.(%{action: "start", name: name, language: "python"})
    policy = RuntimeConfig.fresh(workspace_roots: [workspace])
    assert {:ask, _} = ToolRegistry.dispatch(start_request, policy)
    assert %Result{ok: true} = ToolRegistry.execute(start_request, policy)

    run_request =
      request.(%{action: "run", name: name, code: "counter = 41\n_result = counter + 1"})

    assert %Result{ok: true, output: first} = ToolRegistry.execute(run_request, policy)
    assert Jason.decode!(first)["value"] == "42"

    second = request.(%{action: "run", name: name, code: "_result = counter + 1"})
    assert %Result{ok: true, output: second_output} = ToolRegistry.execute(second, policy)
    assert Jason.decode!(second_output)["value"] == "42"
    assert :ok = EvalHub.stop(name)
  end

  test "bounds a non-terminating evaluation" do
    name = "timeout-python-#{System.unique_integer([:positive])}"
    policy = RuntimeConfig.fresh(tool_evaluation_timeout_ms: 20).tools.evaluation
    assert {:ok, _} = EvalHub.start(name, :python, System.tmp_dir!(), policy)
    assert {:error, :evaluation_timeout} = EvalHub.evaluate(name, "while True: pass")
    assert :ok = EvalHub.stop(name)
  end
end
