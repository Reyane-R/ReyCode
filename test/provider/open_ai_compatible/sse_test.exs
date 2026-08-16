defmodule ReyCode.Provider.OpenAICompatible.SSETest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.OpenAICompatible.SSE

  test "parses complete content deltas separated by blank lines" do
    chunks = [
      ~s(data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n),
      ~s(data: {"choices":[{"delta":{"content":" world"}}]}\n\n)
    ]

    events =
      Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {acc, parser} ->
        {new_events, parser} = SSE.feed(parser, chunk)
        {acc ++ new_events, parser}
      end)
      |> elem(0)

    assert events == [{:text, "Hello"}, {:text, " world"}]
  end

  test "buffers a partial event until the terminator arrives" do
    {events1, parser1} = SSE.feed(SSE.new(), ~s(data: {"choices":[{"delta":{"content":"Ho))
    assert events1 == []

    {events2, _parser2} = SSE.feed(parser1, ~s(t"}}]}\n\n))
    assert events2 == [{:text, "Hot"}]
  end

  test "recognizes the stream terminator" do
    {events, _parser} = SSE.feed(SSE.new(), "data: [DONE]\n\n")
    assert :done in events
  end

  test "extracts usage from a final frame that carries it" do
    payload =
      ~s(data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}\n\n)

    {events, _parser} = SSE.feed(SSE.new(), payload)

    assert {:usage, %{"prompt_tokens" => 10, "completion_tokens" => 5}} in events
  end

  test "ignores malformed payloads without raising" do
    {events, _parser} = SSE.feed(SSE.new(), "data: not-json\n\n")
    assert events == [:ignore]
  end

  test "ignores empty content deltas" do
    {events, _parser} =
      SSE.feed(SSE.new(), ~s(data: {"choices":[{"delta":{"content":""}}]}\n\n))

    assert events == []
  end
end
