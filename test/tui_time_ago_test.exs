defmodule ReyCode.TUI.TimeAgoTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.TimeAgo

  test "formats relative ages in compact units" do
    now = DateTime.utc_now()

    assert TimeAgo.format(DateTime.to_iso8601(now)) == "just now"

    assert TimeAgo.format(now |> DateTime.add(-5, :minute) |> DateTime.to_iso8601()) == "5m ago"

    assert TimeAgo.format(now |> DateTime.add(-3, :hour) |> DateTime.to_iso8601()) == "3h ago"

    assert TimeAgo.format(now |> DateTime.add(-2, :day) |> DateTime.to_iso8601()) == "2d ago"
  end

  test "falls back to a date for older timestamps and empty for invalid input" do
    assert TimeAgo.format(nil) == ""
    assert TimeAgo.format("not-a-timestamp") == ""

    old = DateTime.utc_now() |> DateTime.add(-30, :day)
    formatted = TimeAgo.format(DateTime.to_iso8601(old))
    assert formatted =~ Calendar.strftime(old, "%b")
  end
end
