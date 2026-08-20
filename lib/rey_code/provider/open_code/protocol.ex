defmodule ReyCode.Provider.OpenCode.Protocol do
  @moduledoc "Decodes OpenCode JSON output into provider frames with bounded stream state."

  alias ReyCode.Provider.{Frame, Request, TextBuffer}
  alias ReyCode.Provider.OpenCode.Protocol.State

  @ansi ~r/\e\[[0-?]*[ -\/]*[@-~]/
  @tool_started_states ~w(pending running started start executing)
  @default_diagnostic_bytes 64_000
  @default_output_bytes 10_000_000
  @default_text_chunk_bytes 8_192
  @default_text_chunk_latency_ms 50

  defmodule State do
    @moduledoc false

    @enforce_keys [:text_buffer, :sequence, :diagnostic_limit, :output_limit]
    defstruct buffer: "",
              stderr_buffer: "",
              text_buffer: nil,
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

  @spec new(Request.t()) :: State.t()
  def new(%Request{} = request) do
    diagnostic_limit =
      Application.get_env(:rey_code, :opencode_max_diagnostic_bytes, @default_diagnostic_bytes)

    %State{
      text_buffer:
        TextBuffer.new(
          chunk_bytes:
            Application.get_env(
              :rey_code,
              :opencode_text_chunk_bytes,
              @default_text_chunk_bytes
            ),
          chunk_latency_ms:
            Application.get_env(
              :rey_code,
              :opencode_text_chunk_latency_ms,
              @default_text_chunk_latency_ms
            )
        ),
      sequence: request.resume_from,
      diagnostic_limit: diagnostic_limit,
      output_limit:
        Application.get_env(:rey_code, :opencode_max_output_bytes, @default_output_bytes)
    }
  end

  @spec parse_line(binary()) :: {:ok, map()} | :ignore
  def parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> :ignore
    end
  end

  @spec fold(term(), State.t(), ReyCode.Provider.emit()) ::
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

  @spec finish(State.t()) :: {:ok, map()} | {:error, map()}
  def finish(%State{output_limit_exceeded?: true} = state) do
    {:error, error("output_too_large", "OpenCode output exceeded #{state.output_limit} bytes")}
  end

  def finish(state) do
    cond do
      state.exit_status not in [nil, 0] ->
        message = failure_diagnostics(state, state.exit_status)
        {:error, error("command_failed", message)}

      state.provider_errors != [] ->
        {:error,
         error("provider_error", state.provider_errors |> Enum.reverse() |> Enum.join("\n"))}

      not state.protocol_activity? ->
        {:error,
         error(
           "protocol_error",
           "OpenCode exited successfully without recognized protocol records"
         )}

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
    flush_pending_text(state, emit)
  end

  defp handle_line(line, state, emit) do
    case parse_line(line) do
      {:ok, record} -> handle_record(record, state, emit)
      :ignore -> append_diagnostic(state, line)
    end
  end

  defp handle_record(record, state, emit) do
    case record do
      %{"type" => "text", "part" => %{"text" => text}} when is_binary(text) ->
        buffer_text(state, text, emit)

      %{"type" => "tool_use", "part" => part} ->
        state
        |> flush_pending_text(emit)
        |> emit_tool_event(part, emit)

      %{"type" => "step_finish", "part" => part} ->
        state
        |> flush_pending_text(emit)
        |> emit_frame(emit, :usage, %{usage: %{tokens: part["tokens"], cost: part["cost"]}})

      %{"type" => "error", "error" => value} ->
        state = flush_pending_text(state, emit)

        %{
          state
          | provider_errors: [error_text(value) | state.provider_errors],
            protocol_activity?: true
        }

      _ ->
        state
    end
  end

  defp emit_tool_event(state, part, emit) do
    case part_tool_event(part) do
      {tool_kind, %{tool: tool, state: tool_state}} ->
        emit_frame(state, emit, tool_kind, %{tool: tool, state: tool_state})

      _ ->
        state
    end
  end

  defp part_tool_event(part) when not is_map(part), do: nil

  defp part_tool_event(part) when is_map(part) do
    tool = normalize_tool_name(part["tool"])
    tool_state = part["state"]

    if is_binary(tool) do
      kind = classify_tool_state(tool_state)
      {kind, %{tool: tool, state: tool_state}}
    end
  end

  defp normalize_tool_name(value) when is_binary(value), do: value
  defp normalize_tool_name(_), do: nil

  defp classify_tool_state(%{"status" => status}), do: classify_tool_state(status)

  defp classify_tool_state(status) when is_binary(status) do
    if String.downcase(String.trim(status)) in @tool_started_states,
      do: :tool_started,
      else: :tool_completed
  end

  defp classify_tool_state(_), do: :tool_completed

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
    do: Enum.reduce(chunks, state, &emit_frame(&2, emit, :text_delta, %{text: &1}))

  defp emit_frame(state, emit, kind, data) do
    sequence = state.sequence + 1
    :ok = emit.(%Frame{sequence: sequence, kind: kind, data: data})
    %{state | sequence: sequence, protocol_activity?: true}
  end

  defp append_diagnostic(state, line) do
    line = line |> strip_ansi() |> String.trim()

    cond do
      line == "" ->
        state

      state.diagnostic_bytes >= state.diagnostic_limit ->
        %{state | diagnostics_truncated?: true}

      true ->
        separator_bytes = if state.diagnostics == [], do: 0, else: 1
        available = state.diagnostic_limit - state.diagnostic_bytes - separator_bytes

        if available <= 0 do
          %{state | diagnostics_truncated?: true}
        else
          kept = TextBuffer.truncate_utf8(line, available)

          %{
            state
            | diagnostics: [kept | state.diagnostics],
              diagnostic_bytes: state.diagnostic_bytes + separator_bytes + byte_size(kept),
              diagnostics_truncated?:
                state.diagnostics_truncated? or byte_size(kept) < byte_size(line)
          }
        end
    end
  end

  defp failure_diagnostics(state, status) do
    messages = Enum.reverse(state.provider_errors) ++ Enum.reverse(state.diagnostics)
    message = messages |> Enum.join("\n") |> String.trim()

    message =
      if state.diagnostics_truncated? do
        String.trim(message <> "\n[diagnostics truncated]")
      else
        message
      end

    if message == "", do: "OpenCode exited with status #{status}", else: message
  end

  defp strip_ansi(value), do: Regex.replace(@ansi, value, "")

  defp error_text(value) when is_binary(value), do: value
  defp error_text(%{"data" => %{"message" => message}}), do: message
  defp error_text(value), do: inspect(value)

  defp error(category, message) do
    %{"category" => category, "message" => message, "retryable" => false}
  end
end
