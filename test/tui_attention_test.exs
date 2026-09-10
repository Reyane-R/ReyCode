defmodule ReyCode.TUI.AttentionTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Attention

  test "verification review and indeterminate reconciliation each signal once without focus changes" do
    empty = %{sessions: %{}, invocations: %{}}

    session = %ReyCode.Orchestration.Session{
      verified_change: %ReyCode.Orchestration.VerifiedChange{id: "change", phase: "ready"}
    }

    ready = %{empty | sessions: %{"session" => session}}

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Attention.notify(empty, ready, fn -> true end)
           end) == "\a"

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Attention.notify(ready, ready, fn -> true end)
           end) == ""

    resolution = %ReyCode.Orchestration.VerifiedChangeResolution{
      id: "resolution",
      status: :indeterminate
    }

    uncertain = %{
      ready
      | sessions: %{"session" => %{session | verified_change_resolution: resolution}}
    }

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Attention.notify(ready, uncertain, fn -> true end)
           end) == "\a"

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             Attention.notify(uncertain, uncertain, fn -> true end)
           end) == ""
  end

  test "detects each newly pending approval once" do
    empty = %{invocations: %{}}
    waiting = projection("run-1", :waiting_tool_approval)

    assert Attention.new_approval_ids(empty, waiting) == MapSet.new(["run-1"])
    assert Attention.new_approval_ids(waiting, waiting) == MapSet.new()

    second =
      waiting
      |> put_in([:invocations, "inv-2"], invocation("run-2", :waiting_tool_approval))

    assert Attention.new_approval_ids(waiting, second) == MapSet.new(["run-2"])
  end

  test "ignores resolved and malformed review states" do
    empty = %{invocations: %{}}

    assert Attention.new_approval_ids(empty, projection("run-1", :running)) == MapSet.new()

    malformed = %{
      invocations: %{
        "inv-1" => %{status: :waiting_tool_approval, pending_tool_review: %{request_id: nil}}
      }
    }

    assert Attention.new_approval_ids(empty, malformed) == MapSet.new()
  end

  test "notify is silent without new approvals and signals once with a new approval" do
    empty = %{invocations: %{}}
    waiting = projection("run-1", :waiting_tool_approval)

    assert Attention.notify(empty, empty, fn -> true end) == :ok
    assert Attention.notify(waiting, waiting, fn -> true end) == :ok
    assert Attention.notify(empty, %{}) == :ok
  end

  defp projection(request_id, status),
    do: %{invocations: %{"inv-1" => invocation(request_id, status)}}

  defp invocation(request_id, status),
    do: %{status: status, pending_tool_review: %{request_id: request_id}}
end
