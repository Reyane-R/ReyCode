defmodule ReyCode.HerdrTest do
  use ExUnit.Case, async: true

  alias ReyCode.Herdr

  test "maps durable invocation states to Herdr lifecycle states" do
    assert Herdr.lifecycle(%{invocations: %{one: %{status: :running}}}) == {:working, nil}

    assert Herdr.lifecycle(%{invocations: %{one: %{status: :waiting_operator}}}) ==
             {:blocked, "ReyCode is waiting for an operator decision"}

    assert Herdr.lifecycle(%{invocations: %{one: %{status: :completed}}}) == {:idle, nil}
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

    stop_reporter(reporter, task_supervisor)
  end

  test "does nothing when not running inside Herdr" do
    test_pid = self()
    {reporter, task_supervisor} = start_reporter(test_pid, %{"HERDR_ENV" => "0"})

    Herdr.report(:working, nil, reporter)
    refute_receive {:herdr_command, _, _}, 100

    stop_reporter(reporter, task_supervisor)
  end

  defp start_reporter(
         test_pid,
         env \\ %{
           "HERDR_ENV" => "1",
           "HERDR_PANE_ID" => "w1:p1",
           "HERDR_BIN_PATH" => "/opt/herdr"
         }
       ) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    runner = fn bin_path, args ->
      send(test_pid, {:herdr_command, bin_path, args})
      {"", 0}
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
