defmodule ReyCode.Provider.OMP.Protocol do
  @moduledoc "Decodes OMP RPC events into bounded provider frames."

  alias ReyCode.Failure
  alias ReyCode.Provider.{Frame, Request, TextBuffer}
  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.OMP, as: OMPPolicy

  defmodule State do
    @moduledoc false

    @enforce_keys [:text_buffer, :sequence, :diagnostic_limit, :output_limit]
    defstruct buffer: "",
              stderr_buffer: "",
              text_buffer: nil,
              note_fragments: [],
              sequence: 0,
              provider_errors: [],
              diagnostics: [],
              diagnostic_bytes: 0,
              diagnostics_truncated?: false,
              diagnostic_limit: 0,
              output_bytes: 0,
              output_limit: 0,
              output_limit_exceeded?: false,
              protocol_activity?: false,
              exit_status: nil

    @type t :: %__MODULE__{
            buffer: binary(),
            stderr_buffer: binary(),
            note_fragments: [binary()],
            text_buffer: TextBuffer.t(),
            sequence: non_neg_integer(),
            provider_errors: [binary()],
            diagnostics: [binary()],
            diagnostic_bytes: non_neg_integer(),
            diagnostics_truncated?: boolean(),
            diagnostic_limit: non_neg_integer(),
            output_bytes: non_neg_integer(),
            output_limit: non_neg_integer(),
            output_limit_exceeded?: boolean(),
            protocol_activity?: boolean(),
            exit_status: term()
          }
  end

  @spec new(Request.t(), OMPPolicy.t()) :: State.t()
  def new(%Request{} = request, policy \\ RuntimeConfig.fresh().omp) do
    %State{
      text_buffer:
        TextBuffer.new(
          chunk_bytes: policy.text_chunk_bytes,
          chunk_latency_ms: policy.text_chunk_latency_ms
        ),
      sequence: request.resume_from,
      diagnostic_limit: policy.max_diagnostic_bytes,
      output_limit: policy.max_output_bytes
    }
  end

  @spec parse_line(binary()) :: {:ok, map()} | :ignore
  def parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> :ignore
    end
  end

  @spec fold(term(), State.t(), (Frame.t() -> :ok)) ::
          {:cont, State.t()} | {:halt, State.t()}
  def fold({:exit, {:status, status}}, state, emit) do
    state = flush_buffers(state, emit)
    {:halt, %{state | exit_status: status}}
  end

  def fold({:exit, other}, state, emit) do
    state = flush_buffers(state, emit)
    {:halt, %{state | exit_status: other}}
  end

  def fold({:stdout, data}, state, emit) do
    output_bytes = state.output_bytes + byte_size(data)

    if output_bytes > state.output_limit do
      {:halt, %{state | output_bytes: output_bytes, output_limit_exceeded?: true}}
    else
      {:cont, consume(state.buffer <> data, %{state | output_bytes: output_bytes}, emit)}
    end
  end

  def fold({:stderr, data}, state, _emit) do
    output_bytes = state.output_bytes + byte_size(data)

    if output_bytes > state.output_limit do
      {:halt, %{state | output_bytes: output_bytes, output_limit_exceeded?: true}}
    else
      {:cont, consume_stderr(data, %{state | output_bytes: output_bytes})}
    end
  end

  @spec next_flush_deadline(State.t()) :: integer() | nil
  def next_flush_deadline(%State{text_buffer: buffer}),
    do: TextBuffer.next_flush_deadline(buffer)

  @spec flush_due(State.t(), (Frame.t() -> :ok), integer()) :: State.t()
  def flush_due(%State{} = state, emit, now) do
    {chunks, buffer} = TextBuffer.flush_due(state.text_buffer, now)
    state |> Map.put(:text_buffer, buffer) |> emit_text_chunks(chunks, emit)
  end

  @spec finish(State.t()) :: {:ok, map()} | {:error, Failure.t()}
  def finish(%State{output_limit_exceeded?: true} = state) do
    {:error, error(:output_too_large, "OMP output exceeded #{state.output_limit} bytes")}
  end

  def finish(state) do
    cond do
      state.exit_status not in [nil, 0] ->
        {:error, error(:command_failed, failure_diagnostics(state, state.exit_status))}

      state.provider_errors != [] ->
        {:error,
         error(:provider_error, state.provider_errors |> Enum.reverse() |> Enum.join("\n"))}

      not state.protocol_activity? ->
        {:error, error(:protocol_error, "OMP exited successfully without recognized RPC records")}

      true ->
        {:ok, %{}}
    end
  end

  defp consume(data, state, emit) do
    parts = String.split(data, "\n")
    rest = List.last(parts) || ""

    state =
      parts
      |> Enum.drop(-1)
      |> Enum.reduce(state, fn line, acc -> handle_line(line, acc, emit) end)

    %{state | buffer: rest}
  end

  defp consume_stderr(data, state) do
    parts = String.split(state.stderr_buffer <> data, "\n")
    rest = List.last(parts) || ""

    state =
      parts
      |> Enum.drop(-1)
      |> Enum.reduce(state, fn line, acc -> append_diagnostic(acc, line) end)

    available = max(state.diagnostic_limit - state.diagnostic_bytes, 0)
    kept = TextBuffer.truncate_utf8(rest, available)

    %{
      state
      | stderr_buffer: kept,
        diagnostics_truncated?: state.diagnostics_truncated? or byte_size(kept) < byte_size(rest)
    }
  end

  defp flush_buffers(%State{buffer: stdout_buffer, stderr_buffer: stderr_buffer} = state, emit) do
    state =
      if stdout_buffer == "" do
        state
      else
        consume(stdout_buffer <> "\n", %{state | buffer: ""}, emit)
      end

    state = %{state | stderr_buffer: ""}
    state = if stderr_buffer == "", do: state, else: append_diagnostic(state, stderr_buffer)
    flush_content(state, emit)
  end

  defp handle_line(line, state, emit) do
    case parse_line(line) do
      {:ok, record} -> handle_record(record, state, emit)
      :ignore -> append_diagnostic(state, line)
    end
  end

  defp handle_record(%{"type" => "message_update", "assistantMessageEvent" => event}, state, emit)
       when is_map(event) do
    case Map.get(event, "type") do
      "text_delta" ->
        state
        |> flush_note(emit)
        |> buffer_text(Map.get(event, "delta"), emit)

      "thinking_start" ->
        state
        |> flush_content(emit)
        |> Map.put(:note_fragments, [])
        |> Map.put(:protocol_activity?, true)

      "thinking_delta" ->
        buffer_note(state, Map.get(event, "delta"))

      "thinking_end" ->
        finish_note(state, Map.get(event, "content"), emit)

      _event_type ->
        %{state | protocol_activity?: true}
    end
  end

  defp handle_record(
         %{"type" => "tool_execution_start", "toolName" => tool} = record,
         state,
         emit
       )
       when is_binary(tool) do
    tool_state = %{
      "status" => "running",
      "tool_call_id" => record["toolCallId"],
      "arguments" => record["args"] || %{},
      "intent" => record["intent"]
    }

    state
    |> flush_content(emit)
    |> emit_tool_frame(:started, tool, tool_state, emit)
  end

  defp handle_record(
         %{"type" => "tool_execution_update", "toolName" => tool} = record,
         state,
         emit
       )
       when is_binary(tool) do
    tool_state = %{
      "status" => "running",
      "tool_call_id" => record["toolCallId"],
      "arguments" => record["args"] || %{},
      "partial_result" => record["partialResult"]
    }

    emit_tool_frame(state, :started, tool, tool_state, emit)
  end

  defp handle_record(
         %{"type" => "tool_execution_end", "toolName" => tool} = record,
         state,
         emit
       )
       when is_binary(tool) do
    failed? = record["isError"] == true

    tool_state = %{
      "status" => if(failed?, do: "failed", else: "completed"),
      "tool_call_id" => record["toolCallId"],
      "result" => record["result"],
      "is_error" => failed?
    }

    emit_tool_frame(state, :completed, tool, tool_state, emit)
  end

  defp handle_record(%{"type" => "response", "success" => false} = record, state, emit) do
    state = flush_content(state, emit)

    %{
      state
      | provider_errors: [response_error(record) | state.provider_errors],
        protocol_activity?: true
    }
  end

  defp handle_record(%{"type" => "error"} = record, state, emit) do
    state = flush_content(state, emit)

    %{
      state
      | provider_errors: [
          error_text(record["error"] || record["message"]) | state.provider_errors
        ],
        protocol_activity?: true
    }
  end

  defp handle_record(%{"type" => type}, state, _emit)
       when type in [
              "ready",
              "response",
              "agent_start",
              "message_end",
              "agent_end",
              "prompt_result"
            ],
       do: %{state | protocol_activity?: true}

  defp handle_record(_record, state, _emit), do: state

  defp response_error(record) do
    record
    |> Map.get("error", Map.get(record, "code", "OMP RPC command failed"))
    |> error_text()
  end

  defp error_text(value) when is_binary(value), do: value
  defp error_text(nil), do: "OMP returned an unspecified error"
  defp error_text(value), do: inspect(value)

  defp buffer_note(state, note) when not is_binary(note),
    do: %{state | protocol_activity?: true}

  defp buffer_note(state, ""), do: %{state | protocol_activity?: true}

  defp buffer_note(state, note) do
    %{
      state
      | note_fragments: [note | state.note_fragments],
        protocol_activity?: true
    }
  end

  defp finish_note(state, content, emit) when is_binary(content) and content != "" do
    state
    |> Map.put(:note_fragments, [])
    |> emit_note(content, emit)
  end

  defp finish_note(state, _content, emit), do: flush_note(state, emit)

  defp flush_content(state, emit) do
    state
    |> flush_note(emit)
    |> flush_pending_text(emit)
  end

  defp flush_note(%State{note_fragments: []} = state, _emit), do: state

  defp flush_note(state, emit) do
    note = state.note_fragments |> Enum.reverse() |> IO.iodata_to_binary()

    state
    |> Map.put(:note_fragments, [])
    |> emit_note(note, emit)
  end

  defp emit_note(state, "", _emit), do: state

  defp emit_note(state, note, emit) do
    sequence = state.sequence + 1
    :ok = emit.(Frame.agent_note(sequence, note))
    %{state | sequence: sequence, protocol_activity?: true}
  end

  defp emit_tool_frame(state, kind, tool, tool_state, emit) do
    sequence = state.sequence + 1

    frame =
      case kind do
        :started -> Frame.tool_started(sequence, tool, tool_state)
        :completed -> Frame.tool_completed(sequence, tool, tool_state)
      end

    :ok = emit.(frame)
    %{state | sequence: sequence, protocol_activity?: true}
  end

  defp buffer_text(state, text, _emit) when not is_binary(text),
    do: %{state | protocol_activity?: true}

  defp buffer_text(state, "", _emit), do: %{state | protocol_activity?: true}

  defp buffer_text(state, text, emit) do
    {chunks, buffer} = TextBuffer.append(state.text_buffer, text)

    state
    |> Map.put(:text_buffer, buffer)
    |> Map.put(:protocol_activity?, true)
    |> emit_text_chunks(chunks, emit)
  end

  defp flush_pending_text(state, emit) do
    {chunks, buffer} = TextBuffer.flush(state.text_buffer)
    state |> Map.put(:text_buffer, buffer) |> emit_text_chunks(chunks, emit)
  end

  defp emit_text_chunks(state, chunks, emit),
    do: Enum.reduce(chunks, state, &emit_frame(&2, emit, &1))

  defp emit_frame(state, emit, text) do
    sequence = state.sequence + 1
    :ok = emit.(Frame.text_delta(sequence, text))
    %{state | sequence: sequence, protocol_activity?: true}
  end

  defp append_diagnostic(state, line) do
    line = String.trim(line)

    cond do
      line == "" ->
        state

      state.diagnostic_bytes >= state.diagnostic_limit ->
        %{state | diagnostics_truncated?: true}

      true ->
        separator_bytes = if state.diagnostics == [], do: 0, else: 1
        available = state.diagnostic_limit - state.diagnostic_bytes - separator_bytes
        kept = TextBuffer.truncate_utf8(line, max(available, 0))

        %{
          state
          | diagnostics: if(kept == "", do: state.diagnostics, else: [kept | state.diagnostics]),
            diagnostic_bytes: state.diagnostic_bytes + byte_size(kept) + separator_bytes,
            diagnostics_truncated?:
              state.diagnostics_truncated? or byte_size(kept) < byte_size(line)
        }
    end
  end

  defp failure_diagnostics(state, status) do
    lines = Enum.reverse(state.diagnostics)
    lines = if lines == [], do: ["OMP exited with status #{status}"], else: lines
    suffix = if state.diagnostics_truncated?, do: "\n[diagnostics truncated]", else: ""
    Enum.join(lines, "\n") <> suffix
  end

  defp error(category, message), do: Failure.new(category, message)
end
