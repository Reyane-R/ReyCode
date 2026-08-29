defmodule ReyCode.TUI.ActivityHeaderTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Activity

  test "header text is empty for a nil item" do
    assert Activity.header_text(nil, "⠋") == ""
  end

  test "header text drops the participant target but keeps glyph, label, and elapsed" do
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
end
