defmodule ReyCode.TUI.ActivityHeaderTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Activity

  test "header text is empty for a nil item" do
    assert Activity.header_text(nil, "⠋") == ""
  end

  test "header text drops only the redundant Thinking participant target" do
    item = %Activity.Item{
      id: "inv-1",
      kind: :invocation,
      state: :active,
      label: "Thinking",
      target: "Assistant",
      elapsed_seconds: 5,
      active?: true,
      priority: 80
    }

    assert Activity.header_text(item, "⠋") == "⠋ · Thinking · 5s"
    assert Activity.text(item, "⠋") == "⠋ · Thinking · Assistant · 5s"
  end

  test "header text keeps the retry attempt target" do
    item = %Activity.Item{
      id: "inv-2",
      kind: :invocation,
      state: :active,
      label: "Retrying",
      target: "attempt 2",
      elapsed_seconds: 6,
      active?: true,
      priority: 65
    }

    assert Activity.header_text(item, "⠋") == "⠋ · Retrying · attempt 2 · 6s"
  end

  test "header text keeps a bounded work target for non-invocation activity" do
    item = %Activity.Item{
      id: "run-1",
      kind: :tool,
      state: :active,
      label: "Reading",
      target: "mix.exs",
      elapsed_seconds: 2,
      active?: true,
      priority: 60
    }

    assert Activity.header_text(item, "⠋") == "⠋ · Reading · mix.exs · 2s"
  end
end
