defmodule ReyCode.RunTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ReyCode.Run

  test "prints the response and raises on argument errors" do
    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        Run.run(["-p", "Return a short answer", "--timeout-ms", "5000"])
      end)

    assert output != ""
    assert_raise(Mix.Error, fn -> Run.run(["-p", "one", "two"]) end)
  end
end
