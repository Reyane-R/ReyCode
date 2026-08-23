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

  test "reports malformed payloads without raising or retaining their data" do
    {events, parser} = SSE.feed(SSE.new(), "data: secret-not-json\n\n")
    assert events == [{:protocol_error, :invalid_json}]
    assert SSE.finish(parser) == {:error, :invalid_json}
    refute inspect(events) =~ "secret"
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

  test "starts tools keyed by integer index, string index, and skips keyless calls" do
    by_index = tool_calls_payload([%{"index" => 0, "function" => %{"name" => "list"}}])
    assert [{:tool_started, "list", started}] = SSE.feed(SSE.new(), by_index) |> elem(0)
    assert started["index"] == 0

    by_string_index = tool_calls_payload([%{"index" => "3", "function" => %{"name" => "glob"}}])
    assert [{:tool_started, "glob", _}] = SSE.feed(SSE.new(), by_string_index) |> elem(0)

    keyless = tool_calls_payload([%{"function" => %{"name" => "anon"}}])

    assert {[{:protocol_error, :invalid_tool_call}], _parser} =
             SSE.feed(SSE.new(), keyless)
  end

  test "defers tool start until a name arrives and completes with accumulated arguments" do
    unnamed =
      tool_calls_payload([%{"id" => "call-9", "function" => %{"arguments" => "{\"a\":1}"}}])

    {[], parser} = SSE.feed(SSE.new(), unnamed)

    empty_arguments =
      tool_calls_payload([
        %{"id" => "call-9", "function" => %{"name" => "edit", "arguments" => ""}}
      ])

    {[], parser} = SSE.feed(parser, empty_arguments)

    finish = ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)
    assert [{:tool_completed, "edit", finished}] = SSE.feed(parser, finish) |> elem(0)
    assert finished["arguments"] == ~s({"a":1})
  end

  test "sorts started and completed calls across string indexes and id-only keys" do
    payload =
      tool_calls_payload([
        %{"id" => "call-z", "function" => %{"name" => "by_id"}},
        %{"id" => "call-abc", "index" => "abc", "function" => %{"name" => "unparseable"}},
        %{"id" => "call-10", "index" => "10", "function" => %{"name" => "ten"}},
        %{"id" => "call-2", "index" => "2", "function" => %{"name" => "two"}}
      ])

    assert [
             {:tool_started, "two", _},
             {:tool_started, "ten", _},
             {:tool_started, "unparseable", _},
             {:tool_started, "by_id", _}
           ] = SSE.feed(SSE.new(), payload) |> elem(0)

    finish = ~s(data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}\n\n)

    assert [
             {:tool_completed, "two", _},
             {:tool_completed, "ten", _},
             {:tool_completed, "unparseable", _},
             {:tool_completed, "by_id", _}
           ] = SSE.feed(SSE.new(), payload) |> elem(1) |> then(&SSE.feed(&1, finish)) |> elem(0)
  end

  test "names tools from the top-level tool field" do
    payload = tool_calls_payload([%{"id" => "call-t", "tool" => "read"}])
    assert [{:tool_started, "read", _}] = SSE.feed(SSE.new(), payload) |> elem(0)
  end

  test "is total over malformed choice, content, usage, and tool shapes" do
    malformed = [
      ~s(data: null\n\n),
      ~s(data: {}\n\n),
      ~s(data: {"choices":{}}\n\n),
      ~s(data: {"choices":[null]}\n\n),
      ~s(data: {"choices":[{}]}\n\n),
      ~s(data: {"choices":[{"delta":42}]}\n\n),
      ~s(data: {"choices":[{"delta":{},"finish_reason":42}]}\n\n),
      ~s(data: {"choices":[{"delta":{"content":42}}]}\n\n),
      ~s(data: {"choices":[{"delta":{"tool_calls":{}}}]}\n\n),
      ~s(data: {"choices":[],"usage":42}\n\n)
    ]

    for payload <- malformed do
      assert {[{:protocol_error, _reason}], %SSE{}} = SSE.feed(SSE.new(), payload)
    end
  end

  test "preserves UTF-8 bytes split between transport chunks" do
    payload = ~s(data: {"choices":[{"delta":{"content":"café"}}]}\n\n)
    split_at = :binary.match(payload, <<0xC3, 0xA9>>) |> elem(0) |> Kernel.+(1)
    <<first::binary-size(split_at), second::binary>> = payload

    assert {[], parser} = SSE.feed(SSE.new(), first)
    assert {[{:text, "café"}], parser} = SSE.feed(parser, second)
    assert SSE.finish(parser) == :ok
  end

  test "rejects unterminated tails and incomplete tools at EOF" do
    {[], parser} = SSE.feed(SSE.new(), "data: {\"choices\":[]}")
    assert SSE.finish(parser) == {:error, :unterminated_event}

    payload =
      tool_calls_payload([
        %{"id" => "call-1", "index" => 0, "function" => %{"name" => "read", "arguments" => "{}"}}
      ])

    {_events, parser} = SSE.feed(SSE.new(), payload)
    assert SSE.finish(parser) == {:error, :incomplete_tool_call}
  end

  test "treats DONE as terminal while allowing trailing comments" do
    assert {[:done], parser} = SSE.feed(SSE.new(), "data: [DONE]\n\n")
    assert {[], parser} = SSE.feed(parser, ": heartbeat\n\n")

    assert {[{:protocol_error, :data_after_done}], parser} =
             SSE.feed(parser, ~s(data: {"choices":[{"delta":{"content":"late"}}]}\n\n))

    assert SSE.finish(parser) == {:error, :data_after_done}

    {[_text], parser} =
      SSE.feed(SSE.new(), ~s(data: {"choices":[{"delta":{"content":"ok"}}]}\n\n))

    assert SSE.finish(%{parser | buffer: ": trailing heartbeat\n"}) == :ok

    assert {[{:protocol_error, :data_after_done}], _parser} =
             SSE.feed(
               elem(SSE.feed(SSE.new(), "data: [DONE]\n\n"), 1),
               ~s(data: {"choices":[]}\n\n)
             )
  end

  test "rejects conflicting identity and tool fields across fragments" do
    first =
      tool_calls_payload([
        %{
          "id" => "call-1",
          "index" => 0,
          "type" => "function",
          "function" => %{"name" => "read", "arguments" => "{"}
        }
      ])

    {[_started], parser} = SSE.feed(SSE.new(), first)

    conflicts = [
      %{"id" => "call-2", "index" => 0, "function" => %{"arguments" => "}"}},
      %{"id" => "call-1", "index" => 0, "type" => "other", "function" => %{}},
      %{"id" => "call-1", "index" => 0, "function" => %{"name" => "bash"}}
    ]

    for conflict <- conflicts do
      assert {[{:protocol_error, :invalid_tool_call}], _parser} =
               SSE.feed(parser, tool_calls_payload([conflict]))
    end

    id_only =
      tool_calls_payload([
        %{"id" => "call-id", "function" => %{"name" => "read", "arguments" => "{"}}
      ])

    {[_started], parser} = SSE.feed(SSE.new(), id_only)

    changed_key =
      tool_calls_payload([
        %{
          "id" => "call-id",
          "index" => 0,
          "function" => %{"name" => "bash", "arguments" => "}"}
        }
      ])

    assert {[{:protocol_error, :invalid_tool_call}], _parser} = SSE.feed(parser, changed_key)

    invalid_type =
      tool_calls_payload([
        %{
          "id" => "call-type",
          "index" => 0,
          "type" => "other",
          "function" => %{"name" => "read", "arguments" => "{}"}
        }
      ])

    assert {[{:protocol_error, :invalid_tool_call}], _parser} =
             SSE.feed(SSE.new(), invalid_type)

    conflicting_names =
      tool_calls_payload([
        %{
          "id" => "call-names",
          "index" => 0,
          "tool" => "read",
          "function" => %{"name" => "bash", "arguments" => "{}"}
        }
      ])

    assert {[{:protocol_error, :invalid_tool_call}], _parser} =
             SSE.feed(SSE.new(), conflicting_names)
  end

  defp tool_calls_payload(calls) do
    encoded = Jason.encode!(calls)
    ~s(data: {"choices":[{"delta":{"tool_calls":#{encoded}}}]}\n\n)
  end
end
