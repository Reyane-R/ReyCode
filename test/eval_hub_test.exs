defmodule ReyCode.EvalHubTest do
  use ExUnit.Case, async: true

  alias ReyCode.EvalHub
  alias ReyCode.RuntimeConfig
  alias ReyCode.Security.Environment

  @descendant_flag_delay_s 1
  @absence_window_ms 1_500

  test "stop kills the kernel tree, including background descendants" do
    hub = :"eval_hub_stop_#{System.unique_integer([:positive])}"
    start_supervised!({EvalHub, name: hub})

    flag = survivor_flag("stop")
    name = "stop-#{System.unique_integer([:positive])}"
    policy = RuntimeConfig.fresh().tools.evaluation

    assert {:ok, _snapshot} = EvalHub.start(name, :python, System.tmp_dir!(), policy, hub)
    assert {:ok, _result} = EvalHub.evaluate(name, descendant_code(flag), hub)

    assert :ok = EvalHub.stop(name, hub)

    # Absence cannot be awaited; the window runs past the descendant's
    # would-be write deadline, mirroring the bash timeout-kill proof.
    Process.sleep(@absence_window_ms)
    refute File.exists?(flag), "kernel descendant survived EvalHub.stop"
  end

  test "hub shutdown kills every kernel tree" do
    hub = :"eval_hub_shutdown_#{System.unique_integer([:positive])}"
    # Trapping keeps the shutdown exit signal from taking the test down.
    Process.flag(:trap_exit, true)
    {:ok, hub_pid} = EvalHub.start_link(name: hub)

    flag = survivor_flag("shutdown")
    name = "shutdown-#{System.unique_integer([:positive])}"
    policy = RuntimeConfig.fresh().tools.evaluation

    assert {:ok, _snapshot} = EvalHub.start(name, :python, System.tmp_dir!(), policy, hub_pid)
    assert {:ok, _result} = EvalHub.evaluate(name, descendant_code(flag), hub_pid)

    monitor = Process.monitor(hub_pid)
    :ok = GenServer.stop(hub_pid)
    assert_receive {:DOWN, ^monitor, :process, ^hub_pid, :normal}, 1_000

    Process.sleep(@absence_window_ms)
    refute File.exists?(flag), "kernel descendant survived hub shutdown"
  end

  test "port child owns its process group" do
    {wrapper, args, env} = Environment.wrap("/bin/sleep", ["5"], source: System.get_env())

    options = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, Enum.map(args, &String.to_charlist/1)},
      {:cd, String.to_charlist(System.tmp_dir!())},
      {:env,
       Enum.map(env, fn {name, value} ->
         {String.to_charlist(name), String.to_charlist(value)}
       end)}
    ]

    port = Port.open({:spawn_executable, String.to_charlist(wrapper)}, options)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill_tree(os_pid) end)

    {pgid, 0} = System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(os_pid)])
    assert String.trim(pgid) == Integer.to_string(os_pid)
  end

  defp descendant_code(flag) do
    "import os\nos.system('sleep #{@descendant_flag_delay_s} && touch #{flag} &')"
  end

  defp survivor_flag(case_name) do
    Path.join(
      System.tmp_dir!(),
      "eval_hub_survivor_#{case_name}_#{System.unique_integer([:positive])}.flag"
    )
  end

  defp kill_tree(os_pid) do
    _ = System.cmd("/bin/kill", ["-KILL", "-#{os_pid}"], stderr_to_stdout: true)
    _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
