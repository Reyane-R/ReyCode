defmodule ReyCode.Provider.TextBufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Provider.TextBuffer

  test "keeps text pending below both thresholds" do
    buffer = TextBuffer.new(chunk_bytes: 8, chunk_latency_ms: 50)

    assert {[], buffer} = TextBuffer.append(buffer, "hello", 100)
    assert buffer.pending == "hello"
    assert buffer.started_at == 100
  end

  test "size-triggered chunking can retain a short tail" do
    buffer = TextBuffer.new(chunk_bytes: 4, chunk_latency_ms: 100)

    assert {["abcd"], buffer} = TextBuffer.append(buffer, "abcdef", 100)
    assert buffer.pending == "ef"
    assert buffer.started_at == 100
  end

  test "size-triggered chunking can flush the short tail" do
    buffer =
      TextBuffer.new(chunk_bytes: 4, chunk_latency_ms: 100, flush_tail_on_size?: true)

    assert {["abcd", "ef"], buffer} = TextBuffer.append(buffer, "abcdef", 100)
    assert buffer.pending == ""
    assert buffer.started_at == nil
  end

  test "latency-triggered flush emits the entire pending value" do
    buffer = TextBuffer.new(chunk_bytes: 8, chunk_latency_ms: 50)
    {[], buffer} = TextBuffer.append(buffer, "hello", 100)

    assert {["hello!"], buffer} = TextBuffer.append(buffer, "!", 150)
    assert buffer.pending == ""
  end

  test "flush emits a pending short tail" do
    buffer = TextBuffer.new(chunk_bytes: 8, chunk_latency_ms: 50)
    {[], buffer} = TextBuffer.append(buffer, "hello", 100)

    assert {["hello"], buffer} = TextBuffer.flush(buffer, 125)
    assert buffer.pending == ""
  end

  test "chunk boundaries remain valid UTF-8" do
    buffer = TextBuffer.new(chunk_bytes: 3, chunk_latency_ms: 100)

    assert {[first], buffer} = TextBuffer.append(buffer, "éé", 100)
    assert first == "é"
    assert String.valid?(first)
    assert buffer.pending == "é"

    assert {["é"], buffer} = TextBuffer.flush(buffer, 101)
    assert buffer.pending == ""
  end

  test "generic truncation never exceeds its byte limit" do
    assert TextBuffer.truncate_utf8("é", 1) == ""
    assert TextBuffer.truncate_utf8("é", 2) == "é"
  end

  test "rejects invalid limits" do
    assert_raise ArgumentError, fn ->
      TextBuffer.new(chunk_bytes: 0, chunk_latency_ms: 50)
    end

    assert_raise ArgumentError, fn ->
      TextBuffer.new(chunk_bytes: 8, chunk_latency_ms: -1)
    end
  end

  property "forced chunking preserves valid UTF-8 text exactly" do
    check all(text <- string(:printable), chunk_bytes <- integer(1..32)) do
      buffer = TextBuffer.new(chunk_bytes: chunk_bytes, chunk_latency_ms: 0)
      {chunks, buffer} = TextBuffer.append(buffer, text, 0)

      assert Enum.all?(chunks, &String.valid?/1)
      assert IO.iodata_to_binary(chunks) <> buffer.pending == text
    end
  end

  property "UTF-8 truncation returns a valid prefix within the byte limit" do
    check all(text <- string(:printable), max_bytes <- integer(0..128)) do
      truncated = TextBuffer.truncate_utf8(text, max_bytes)

      assert String.valid?(truncated)
      assert byte_size(truncated) <= max_bytes
      assert String.starts_with?(text, truncated)
    end
  end
end
