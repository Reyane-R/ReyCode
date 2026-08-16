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

  test "reassembles multiline data blocks before JSON decoding" do
    payload = ~s(data: {\ndata:   "choices":[{"delta":{"content":"Hello"}}]\ndata: }\n\n)

    {events, _parser} = SSE.feed(SSE.new(), payload)

    assert events == [{:text, "Hello"}]
  end

  test "buffers partial multiline frames until terminator arrives" do
    parser = SSE.new()
    partial_1 = "data: {\n" <> "data:   \"choices\":[{\"delta\":{\"content\":\"Hot\"}}]\n"
    partial_2 = "data: }\n\n"

    {events_1, parser_1} = SSE.feed(parser, partial_1)
    assert events_1 == []

    {events_2, _parser_2} = SSE.feed(parser_1, partial_2)
    assert events_2 == [{:text, "Hot"}]
  end

  test "sorts started tool calls by index" do
    payload =
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-second","index":1,"type":"function","function":{"name":"second","arguments":"{}"}},{"id":"call-first","index":0,"type":"function","function":{"name":"first","arguments":"{}"}}]}}]}\n\n)

    assert [
             {:tool_started, "first", first_started},
             {:tool_started, "second", second_started}
           ] = SSE.feed(SSE.new(), payload) |> elem(0)

    assert first_started["index"] == 0
    assert second_started["index"] == 1
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

  test "tracks started and completed tool calls across chunks" do
    parser = SSE.new()

    chunk_1 =
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1","index":0,"type":"function","function":{"name":"search","arguments":"{\\\"q\\\":\\\"he"}}]}}]}\n\n)

    {events_1, parser_1} = SSE.feed(parser, chunk_1)
    assert [{:tool_started, "search", started}] = events_1
    assert started["id"] == "call-1"
    assert started["arguments"] == ~s({"q":"he)

    chunk_2 =
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1","index":0,"function":{"arguments":"llo\\\"}"}}]}}]}\n\n)

    {events_2, parser_2} = SSE.feed(parser_1, chunk_2)
    assert events_2 == []

    chunk_3 = ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
    {events_3, _parser_3} = SSE.feed(parser_2, chunk_3)
    assert [completed] = events_3
    assert {:tool_completed, "search", finished} = completed
    assert finished["arguments"] == ~s({"q":"hello"})
  end

  test "sorts completed tool calls by index" do
    payload =
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"id":"call-second","index":1,"type":"function","function":{"name":"second","arguments":"{}"}},{"id":"call-first","index":0,"type":"function","function":{"name":"first","arguments":"{}"}}]}}]}\n\n)

    {start_events, parser} = SSE.feed(SSE.new(), payload)
    assert length(start_events) == 2

    finish_payload = ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
    {finish_events, _} = SSE.feed(parser, finish_payload)

    assert [
             {:tool_completed, "first", first},
             {:tool_completed, "second", second}
           ] = finish_events

    assert first["index"] == 0
    assert second["index"] == 1
  end
end
