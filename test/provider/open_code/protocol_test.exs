defmodule ReyCode.Provider.OpenCode.ProtocolTest do
  use ExUnit.Case, async: false

  import ReyCode.Test.OpenCodeHelpers,
    only: [collect_frames: 1, request: 0, restore_env: 2, text_record: 1]

  alias ReyCode.Provider.OpenCode.Protocol

  test "maps OpenCode JSON output into session and text frames" do
    {result, frames} =
      run([
        {:stdout, text_record("Hello from OpenCode")},
        {:exit, {:status, 0}}
      ])

    assert result == {:ok, %{session_id: "session-1"}}

    assert [
             %{kind: :session_started, sequence: 1},
             %{kind: :text_delta, sequence: 2, data: %{text: "Hello from OpenCode"}}
           ] = frames
  end

  test "classifies running and completed OpenCode tool lifecycle states" do
    {_result, frames} =
      run([
        {:stdout, tool_use_record(%{tool: "bash", state: "  PENDING "})},
        {:stdout, tool_use_record(%{tool: "bash", state: %{"status" => "completed"}})},
        {:exit, {:status, 0}}
      ])

    assert [
             %{kind: :session_started, sequence: 1},
             %{kind: :tool_started, sequence: 2, data: %{tool: "bash", state: "  PENDING "}},
             %{
               kind: :tool_completed,
               sequence: 3,
               data: %{tool: "bash", state: %{"status" => "completed"}}
             }
           ] = frames
  end

  test "treats tool_use state maps without status as completed" do
    {_result, frames} =
      run([
        {:stdout, tool_use_record(%{tool: "bash", state: %{"output" => "done"}})},
        {:exit, {:status, 0}}
      ])

    assert [
             %{kind: :session_started, sequence: 1},
             %{
               kind: :tool_completed,
               sequence: 2,
               data: %{tool: "bash", state: %{"output" => "done"}}
             }
           ] = frames
  end

  test "assembles a JSON record split across port data messages" do
    {_result, frames} =
      run([
        {:stdout, ~s({"type":"text","sessionID":"session-1","part":)},
        {:stdout, ~s({"text":"partial JSON"}}\n)},
        {:exit, {:status, 0}}
      ])

    assert [_, %{kind: :text_delta, data: %{text: "partial JSON"}}] = frames
  end

  test "keeps non-JSON output as diagnostics when the command succeeds" do
    {result, frames} =
      run([
        {:stdout, "warming provider cache\n"},
        {:stdout, text_record("successful response")},
        {:exit, {:status, 0}}
      ])

    assert result == {:ok, %{session_id: "session-1"}}

    assert Enum.any?(
             frames,
             &match?(%{kind: :text_delta, data: %{text: "successful response"}}, &1)
           )
  end

  test "returns a protocol error when successful output has no recognized records" do
    {result, _frames} =
      run([
        {:stdout, "warming provider cache\n"},
        {:stdout, ~s({"type":"unknown"}\n)},
        {:exit, {:status, 0}}
      ])

    assert {:error,
            %{
              "category" => "protocol_error",
              "message" => "OpenCode exited successfully without recognized protocol records",
              "retryable" => false
            }} = result
  end

  test "returns bounded diagnostics for a nonzero exit" do
    previous = Application.get_env(:rey_code, :opencode_max_diagnostic_bytes)
    Application.put_env(:rey_code, :opencode_max_diagnostic_bytes, 10)

    on_exit(fn -> restore_env(:opencode_max_diagnostic_bytes, previous) end)

    {result, _frames} =
      run([
        {:stderr, "authentication failed\n"},
        {:exit, {:status, 7}}
      ])

    assert {:error,
            %{
              "category" => "command_failed",
              "message" => "authentica\n[diagnostics truncated]",
              "retryable" => false
            }} = result
  end

  test "counts newline-free stderr against total output and bounds retained diagnostics" do
    previous_output = Application.get_env(:rey_code, :opencode_max_output_bytes)
    previous_diagnostics = Application.get_env(:rey_code, :opencode_max_diagnostic_bytes)

    on_exit(fn ->
      restore_env(:opencode_max_output_bytes, previous_output)
      restore_env(:opencode_max_diagnostic_bytes, previous_diagnostics)
    end)

    stderr = [{:stderr, String.duplicate("x", 100)}, {:exit, {:status, 7}}]

    Application.put_env(:rey_code, :opencode_max_output_bytes, 50)
    Application.put_env(:rey_code, :opencode_max_diagnostic_bytes, 10)

    assert {:error, %{"category" => "output_too_large"}} = elem(run(stderr), 0)

    Application.put_env(:rey_code, :opencode_max_output_bytes, 1_000)

    assert {:error,
            %{
              "category" => "command_failed",
              "message" => "xxxxxxxxxx\n[diagnostics truncated]"
            }} = elem(run(stderr), 0)
  end

  test "coalesces adjacent text records into bounded durable frames" do
    previous_bytes = Application.get_env(:rey_code, :opencode_text_chunk_bytes)
    previous_latency = Application.get_env(:rey_code, :opencode_text_chunk_latency_ms)

    on_exit(fn ->
      restore_env(:opencode_text_chunk_bytes, previous_bytes)
      restore_env(:opencode_text_chunk_latency_ms, previous_latency)
    end)

    Application.put_env(:rey_code, :opencode_text_chunk_bytes, 16)
    Application.put_env(:rey_code, :opencode_text_chunk_latency_ms, 60_000)

    body = Enum.map_join(1..100, fn _index -> text_record("x") end)

    {result, frames} =
      run([
        {:stdout, body},
        {:exit, {:status, 0}}
      ])

    assert {:ok, _metadata} = result

    text_frames = Enum.filter(frames, &(&1.kind == :text_delta))

    assert length(text_frames) == 7
    assert Enum.all?(text_frames, &(byte_size(&1.data.text) <= 16))
    assert Enum.map_join(text_frames, & &1.data.text) == String.duplicate("x", 100)
    assert Enum.map(frames, & &1.sequence) == Enum.to_list(1..8)
  end

  test "treats abnormal exit reasons as command failures" do
    {result, _frames} =
      run([
        {:stdout, text_record("partial work")},
        {:exit, :killed}
      ])

    assert {:error,
            %{
              "category" => "command_failed",
              "message" => "OpenCode exited with status killed",
              "retryable" => false
            }} = result
  end

  test "flushes a buffered stdout record on exit" do
    {result, frames} =
      run([
        {:stdout, ~s({"type":"text","sessionID":"session-1","part":{"text":"tail"}})},
        {:exit, {:status, 0}}
      ])

    assert {:ok, %{session_id: "session-1"}} = result
    assert Enum.any?(frames, &match?(%{kind: :text_delta, data: %{text: "tail"}}, &1))
  end

  test "joins provider error records by shape" do
    {result, _frames} =
      run([
        {:stdout, ~s({"type":"error","error":"quota exhausted"}\n)},
        {:stdout, ~s({"type":"error","error":{"data":{"message":"upstream refused"}}}\n)},
        {:stdout, ~s({"type":"error","error":42}\n)},
        {:exit, {:status, 0}}
      ])

    assert {:error,
             %{
               "category" => "provider_error",
               "message" => "quota exhausted\nupstream refused\n42"
             }} = result
  end

  test "ignores tool_use records without a usable part or tool name" do
    {result, frames} =
      run([
        {:stdout, ~s({"type":"tool_use","sessionID":"session-1","part":"not-a-map"}\n)},
        {:stdout, ~s({"type":"tool_use","sessionID":"session-1","part":{"tool":null,"state":"running"}}\n)},
        {:stdout, ~s({"type":"tool_use","sessionID":"session-1","part":{"tool":"bash","state":{"status":"pending"}}}\n)},
        {:exit, {:status, 0}}
      ])

    assert {:ok, %{session_id: "session-1"}} = result
    assert [%{kind: :tool_started, data: %{tool: "bash"}}] = Enum.drop(frames, 1)
  end

  test "marks empty text records as protocol activity without emitting frames" do
    {result, frames} =
      run([
        {:stdout, ~s({"type":"text","sessionID":"session-1","part":{"text":""}}\n)},
        {:exit, {:status, 0}}
      ])

    assert {:ok, %{session_id: "session-1"}} = result
    assert [%{kind: :session_started}] = frames
  end

  test "keeps full diagnostics when under the limit" do
    {result, _frames} =
      run([
        {:stderr, "one line\n"},
        {:stderr, "\n"},
        {:stderr, "two line"},
        {:exit, {:status, 3}}
      ])

    assert {:error,
             %{
               "category" => "command_failed",
               "message" => "one line\ntwo line",
               "retryable" => false
             }} = result
  end

  test "marks diagnostics truncated when a separator no longer fits" do
    previous = Application.get_env(:rey_code, :opencode_max_diagnostic_bytes)
    Application.put_env(:rey_code, :opencode_max_diagnostic_bytes, 10)
    on_exit(fn -> restore_env(:opencode_max_diagnostic_bytes, previous) end)

    {result, _frames} =
      run([
        {:stderr, "0123456789\n"},
        {:stderr, "x"},
        {:exit, {:status, 3}}
      ])

    assert {:error,
             %{
               "category" => "command_failed",
               "message" => "0123456789\n[diagnostics truncated]"
             }} = result
  end

  defp run(elements) do
    test_pid = self()
    emit = emit_frame(test_pid)
    state = Protocol.new(request())

    state = Enum.reduce_while(elements, state, &fold_element(&1, &2, emit))

    {Protocol.finish(state), collect_frames([])}
  end

  defp fold_element(element, state, emit) do
    case Protocol.fold(element, state, emit) do
      {:cont, next} -> {:cont, next}
      {:halt, next} -> {:halt, next}
    end
  end

  defp emit_frame(test_pid) do
    fn frame ->
      send(test_pid, {:frame, frame})
      :ok
    end
  end

  defp tool_use_record(part) do
    Jason.encode!(%{type: "tool_use", sessionID: "session-1", part: part}) <> "\n"
  end
end
