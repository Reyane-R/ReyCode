defmodule ReyCode.HerdrTest do
  use ExUnit.Case, async: true

  alias ReyCode.Herdr
  alias ReyCode.Orchestration.Projection

  defmodule SnapshotEngine do
    use GenServer

    def start_link(projection), do: GenServer.start_link(__MODULE__, projection)

    @impl true
    def init(projection), do: {:ok, projection}

    @impl true
    def handle_call(:snapshot, _from, projection), do: {:reply, projection, projection}
  end

  test "maps durable invocation states to Herdr lifecycle states" do
    assert Herdr.lifecycle(%Projection{invocations: %{one: %{status: :running}}}) ==
             {:working, nil}

    assert Herdr.lifecycle(%Projection{
             invocations: %{one: %{status: :waiting_operator}}
           }) ==
             {:blocked, "ReyCode is waiting for an operator decision"}

    assert Herdr.lifecycle(%Projection{invocations: %{one: %{status: :completed}}}) ==
             {:idle, nil}
  end

  test "reports the Engine snapshot when the isolated reporter starts after the TUI" do
    test_pid = self()
    projection = %Projection{invocations: %{one: %{status: :running}}}
    {:ok, engine} = SnapshotEngine.start_link(projection)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    runner = fn bin_path, args ->
      send(test_pid, {:herdr_command, bin_path, args})
      :ok
    end

    {:ok, reporter} =
      Herdr.start_link(
        name: nil,
        env: herdr_env(),
        engine: engine,
        runner: runner,
        task_supervisor: task_supervisor,
        sequence: 0
      )

    assert_receive {:herdr_command, "/opt/herdr", args}, 1_000
    assert "working" in args

    stop_reporter(reporter, task_supervisor)
    GenServer.stop(engine)
  end

  test "reports ordered state and release commands inside Herdr" do
    test_pid = self()
    {reporter, task_supervisor} = start_reporter(test_pid)

    Herdr.report(:working, nil, reporter)
    assert_receive {:herdr_command, "/opt/herdr", report_args}, 1_000

    assert report_args == [
             "pane",
             "report-agent",
             "w1:p1",
             "--source",
             "custom:reycode",
             "--agent",
             "reycode",
             "--state",
             "working",
             "--seq",
             "1"
           ]

    Herdr.report(:blocked, "Choose an approval", reporter)
    assert_receive {:herdr_command, "/opt/herdr", blocked_args}, 1_000

    assert blocked_args == [
             "pane",
             "report-agent",
             "w1:p1",
             "--source",
             "custom:reycode",
             "--agent",
             "reycode",
             "--state",
             "blocked",
             "--seq",
             "2",
             "--message",
             "Choose an approval"
           ]

    Herdr.release(reporter)
    assert_receive {:herdr_command, "/opt/herdr", release_args}, 1_000

    assert release_args == [
             "pane",
             "release-agent",
             "w1:p1",
             "--source",
             "custom:reycode",
             "--agent",
             "reycode",
             "--seq",
             "3"
           ]

    assert Herdr.release(reporter) == :ok
    refute_receive {:herdr_command, _, _}, 100

    stop_reporter(reporter, task_supervisor)
  end

  test "does nothing when not running inside Herdr" do
    test_pid = self()
    {reporter, task_supervisor} = start_reporter(test_pid, %{"HERDR_ENV" => "0"})

    Herdr.report(:working, nil, reporter)
    Herdr.release(reporter)
    refute_receive {:herdr_command, _, _}, 100

    stop_reporter(reporter, task_supervisor)
  end

  test "release is best effort when the reporter is unavailable" do
    refute Process.whereis(:missing_herdr_reporter)
    assert Herdr.release(:missing_herdr_reporter) == :ok
  end

  test "drops a stale pending transition when lifecycle returns to the in-flight state" do
    test_pid = self()

    runner = fn bin_path, args ->
      send(test_pid, {:herdr_command, bin_path, args, self()})

      receive do
        :finish -> :ok
      end
    end

    {reporter, task_supervisor} = start_reporter(test_pid, herdr_env(), runner)

    Herdr.report(:working, nil, reporter)
    assert_receive {:herdr_command, "/opt/herdr", _working_args, runner_pid}, 1_000

    Herdr.report(:blocked, "Approval", reporter)
    Herdr.report(:working, nil, reporter)
    send(runner_pid, :finish)

    refute_receive {:herdr_command, _, _, _}, 150
    stop_reporter(reporter, task_supervisor)
  end

  test "serializes commands and keeps only the newest pending transition" do
    test_pid = self()

    runner = fn bin_path, args ->
      send(test_pid, {:herdr_command, bin_path, args, self()})

      receive do
        :finish -> :ok
      end
    end

    {reporter, task_supervisor} = start_reporter(test_pid, herdr_env(), runner)

    Herdr.report(:working, nil, reporter)
    assert_receive {:herdr_command, "/opt/herdr", working_args, working_pid}, 1_000
    assert "working" in working_args

    Herdr.report(:blocked, "Approval", reporter)
    send(working_pid, :finish)

    assert_receive {:herdr_command, "/opt/herdr", blocked_args, blocked_pid}, 1_000
    assert "blocked" in blocked_args
    send(blocked_pid, :finish)

    stop_reporter(reporter, task_supervisor)
  end

  test "release waits for its bounded command attempt to finish" do
    test_pid = self()

    runner = fn bin_path, args ->
      send(test_pid, {:herdr_command, bin_path, args, self()})

      receive do
        :finish -> :ok
      end
    end

    {reporter, task_supervisor} = start_reporter(test_pid, herdr_env(), runner)
    release_task = Task.async(fn -> Herdr.release(reporter) end)

    assert_receive {:herdr_command, "/opt/herdr", release_args, runner_pid}, 1_000
    assert "release-agent" in release_args
    assert Task.yield(release_task, 50) == nil

    Herdr.report(:working, nil, reporter)

    send(runner_pid, :finish)
    assert Task.await(release_task, 1_000) == :ok
    refute_receive {:herdr_command, _, _, _}, 100
    stop_reporter(reporter, task_supervisor)
  end

  test "runner failure is isolated and still completes release" do
    test_pid = self()

    runner = fn bin_path, args ->
      send(test_pid, {:herdr_command, bin_path, args})
      exit(:herdr_failed)
    end

    {reporter, task_supervisor} = start_reporter(test_pid, herdr_env(), runner)

    Herdr.report(:working, nil, reporter)
    assert_receive {:herdr_command, "/opt/herdr", _working_args}, 1_000

    assert Herdr.release(reporter) == :ok
    assert_receive {:herdr_command, "/opt/herdr", release_args}, 1_000
    assert "release-agent" in release_args
    assert Process.alive?(reporter)

    stop_reporter(reporter, task_supervisor)
  end

  test "nonzero Herdr CLI exits do not affect the reporter" do
    false_path = System.find_executable("false")
    assert is_binary(false_path)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, reporter} =
      Herdr.start_link(
        name: nil,
        env: Map.put(herdr_env(), "HERDR_BIN_PATH", false_path),
        task_supervisor: task_supervisor,
        sequence: 0
      )

    Herdr.report(:working, nil, reporter)
    assert Herdr.release(reporter) == :ok
    assert Process.alive?(reporter)

    stop_reporter(reporter, task_supervisor)
  end

  defp herdr_env do
    %{
      "HERDR_ENV" => "1",
      "HERDR_PANE_ID" => "w1:p1",
      "HERDR_BIN_PATH" => "/opt/herdr"
    }
  end

  defp start_reporter(test_pid, env \\ herdr_env(), custom_runner \\ nil) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    runner =
      custom_runner ||
        fn bin_path, args ->
          send(test_pid, {:herdr_command, bin_path, args})
          :ok
        end

    {:ok, reporter} =
      Herdr.start_link(
        name: nil,
        env: env,
        runner: runner,
        task_supervisor: task_supervisor,
        sequence: 0
      )

    {reporter, task_supervisor}
  end

  defp stop_reporter(reporter, task_supervisor) do
    :ok = GenServer.stop(reporter)
    :ok = GenServer.stop(task_supervisor)
  end
end
