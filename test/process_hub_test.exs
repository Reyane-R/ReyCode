defmodule ReyCode.ProcessHubTest do
  use ExUnit.Case, async: true

  alias ReyCode.ProcessHub
  alias ReyCode.RuntimeConfig

  test "owns process lifecycle, readiness, bounded logs, and restart" do
    name = :"process_hub_test_#{System.unique_integer([:positive])}"
    start_supervised!({ProcessHub, name: name})

    policy =
      RuntimeConfig.fresh(
        tool_process_max_output_bytes: 32,
        tool_process_stop_timeout_ms: 1_000
      ).tools.process

    command = ["/bin/sh", "-c", "printf '0123456789-ready'; sleep 5"]

    assert {:ok, %{status: :running}} =
             ProcessHub.start("web", command, System.tmp_dir!(), policy, name)

    assert {:ok, logs} = ProcessHub.await("web", "ready", 1_000, name)
    assert logs["output"] =~ "ready"

    assert :ok = ProcessHub.stop("web", name)
    assert [%{name: "web", status: :stopped}] = ProcessHub.list(name)

    assert {:ok, %{status: :running}} = ProcessHub.restart("web", name)
    assert :ok = ProcessHub.stop("web", name)
  end

  test "retains only the newest configured output bytes" do
    name = :"process_hub_bound_#{System.unique_integer([:positive])}"
    start_supervised!({ProcessHub, name: name})

    policy = RuntimeConfig.fresh(tool_process_max_output_bytes: 8).tools.process
    command = ["/bin/sh", "-c", "printf 'abcdefghijklmnop'; sleep 1"]

    assert {:ok, _snapshot} =
             ProcessHub.start("bounded", command, System.tmp_dir!(), policy, name)

    assert {:ok, logs} = ProcessHub.await("bounded", "ijklmnop", 1_000, name)
    assert logs["output"] == "ijklmnop"
    assert logs["truncated"]
    assert logs["output_bytes"] == 8
    assert :ok = ProcessHub.stop("bounded", name)
  end
end
