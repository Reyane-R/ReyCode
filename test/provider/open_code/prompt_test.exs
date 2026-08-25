defmodule ReyCode.Provider.OpenCode.PromptTest do
  use ExUnit.Case, async: true

  import ReyCode.Test.OpenCodeHelpers, only: [request: 0]

  alias ReyCode.Provider.Message
  alias ReyCode.Provider.OpenCode.Prompt

  test "includes the system prompt, participant identity, and history" do
    prompt = Prompt.build(request())

    assert prompt =~ "Respond concisely"
    assert prompt =~ "You are responding as Builder with the perspective: implementation."
    assert prompt =~ "Conversation context:"
    assert prompt =~ "You: Hello"
    assert prompt =~ "Respond to the latest user request."
  end

  test "falls back to the role name when an author has no name" do
    request = %{request() | messages: [Message.new(role: :user, content: "Hi", author: %{})]}
    assert Prompt.build(request) =~ "user: Hi"
  end

  test "includes every conversation message in order" do
    messages = [
      Message.new(role: :user, content: "First", author: %{name: "Alice"}),
      Message.new(role: :assistant, content: "Second", author: %{name: "Bob"})
    ]

    prompt = Prompt.build(%{request() | messages: messages})

    assert prompt =~ "Alice: First"
    assert prompt =~ "Bob: Second"
    assert String.contains?(prompt, "Alice: First\n\nBob: Second")
  end
end
