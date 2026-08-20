defmodule ReyCode.Provider.FrameTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.Frame

  test "constructors produce valid typed frames" do
    assert :ok = Frame.validate(Frame.text_delta(1, "hello"))
    assert :ok = Frame.validate(Frame.usage(3, %{output_tokens: 2}))
    assert :ok = Frame.validate(Frame.tool_started(4, "bash", %{status: "running"}))
    assert :ok = Frame.validate(Frame.tool_completed(5, "bash", %{status: "completed"}))
  end

  test "rejects malformed sequences and payloads" do
    assert {:error, :invalid_frame} =
             Frame.validate(%Frame{sequence: 0, kind: :text_delta, data: %{text: "bad"}})

    assert {:error, :invalid_frame} =
             Frame.validate(%Frame{sequence: 1, kind: :text_delta, data: %{text: 42}})

    assert {:error, :invalid_frame} =
             Frame.validate(%Frame{sequence: 1, kind: :tool_completed, data: %{tool: "bash"}})

    assert {:error, :invalid_frame} =
             Frame.validate(Frame.tool_completed(1, "bash", self()))
  end
end
