defmodule ReyCode.TUI.NoticeTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Notice

  test "informational and successful feedback is not classified from failure-like wording" do
    message = "Could not run the previous request"
    info = Notice.new(:info, message)
    success = Notice.new(:success, message)

    assert Notice.text_class(info) == "text-primary"
    assert Notice.label(info) == "Info"
    assert Notice.text_class(success) == "text-success"
    assert Notice.label(success) == "Success"
  end

  test "warnings and failures retain their distinct severity even with success-like wording" do
    warning = Notice.new(:warning, "Setup completed")
    error = Notice.new(:error, "Setup completed")

    assert Notice.text_class(warning) == "text-warning"
    assert Notice.label(warning) == "Warning"
    assert Notice.text_class(error) == "text-error"
    assert Notice.label(error) == "Error"
  end

  test "invalid notice severity and non-text feedback are rejected" do
    assert_raise FunctionClauseError, fn -> Notice.new(:critical, "Not supported") end
    assert_raise FunctionClauseError, fn -> Notice.new(:info, nil) end
  end
end
