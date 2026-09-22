defmodule ReyCode.Provider.OpenAICompatible.Stream do
  @moduledoc "Owns one bounded provider stream from transport launch through normalized response."

  alias ReyCode.Provider.{Frame, Response, TextBuffer, ToolCall}
  alias ReyCode.Provider.OpenAICompatible.{HTTP, SSE}
  @protocol_error_message "Provider returned an invalid streaming response"

  defmodule Context do
    @moduledoc false

    # `body` is built per attempt by capability negotiation in
    # OpenAICompatible, so the initial context may carry nil.
    @enforce_keys [:transport, :profile, :key, :request, :emit, :config]
    defstruct [:transport, :profile, :key, :request, :body, :emit, :config]
  end

  defmodule StreamTask do
    @moduledoc false

    @enforce_keys [:pid, :ref]
    defstruct [:pid, :ref]
  end

  defmodule Session do
    @moduledoc false

    @enforce_keys [:task, :tag, :context, :deadline, :timeout]
    defstruct [:task, :tag, :context, :deadline, :timeout]
  end

  def run(%Context{profile: profile} = context) do
    timeout = profile.request_timeout_ms
    owner = Process.alias()
    tag = make_ref()
    deadline = monotonic_ms() + timeout
    state = initial_state(profile, context.request, context.config)
    task = start_stream_task(context, owner, tag)

    session =
      %Session{task: task, tag: tag, context: context, deadline: deadline, timeout: timeout}

    try do
      await_stream(session, state)
    rescue
      exception ->
        stop_stream_task(task)
        cancel_relays(tag, cancellation_error())

        {:error,
         HTTP.error(
           :launch_failed,
           "Provider stream crashed: #{Exception.message(exception)}",
           false
         )}
    catch
      kind, reason ->
        stop_stream_task(task)
        cancel_relays(tag, cancellation_error())

        {:error,
         HTTP.error(
           :launch_failed,
           "Provider stream crashed: #{Exception.format_banner(kind, reason)}",
           false
         )}
    after
      Process.unalias(owner)
    end
  end

  defp stream_task(%Context{} = context, owner, tag) do
    %{transport: transport, profile: profile, key: key, body: body} = context
    transport_owner = self()
    url = base_url(profile) <> "/chat/completions"
    headers = authorization(key) ++ [{"Accept", "text/event-stream"}]
    opts = [timeout: profile.request_timeout_ms]

    with {:ok, ref} <- transport.start(:post, url, headers, body, opts),
         {:ok, _acc, final} <-
           transport.collect(
             ref,
             &relay_event(owner, transport_owner, tag, &1, &2),
             :ok
           ) do
      {:ok, final}
    end
  end

  defp start_stream_task(context, owner, tag) do
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = stream_task(context, owner, tag)
        send(caller, {tag, :stream_result, self(), result})
      end)

    %StreamTask{pid: pid, ref: ref}
  end

  defp relay_event(owner, transport_owner, tag, event, acc) do
    acknowledgement = make_ref()
    monitor = Process.monitor(transport_owner)
    send(owner, {tag, :event, self(), acknowledgement, event})

    receive do
      {^tag, ^acknowledgement, :cont} ->
        Process.demonitor(monitor, [:flush])
        {:cont, acc}

      {^tag, ^acknowledgement, {:halt, error}} ->
        Process.demonitor(monitor, [:flush])
        {:halt, acc, error}

      # The owning session enforces the provider deadline; timeout shutdown kills
      # the transport task, which triggers this monitor and bounds the wait.

      {:DOWN, ^monitor, :process, ^transport_owner, _reason} ->
        {:halt, acc, cancellation_error()}
    end
  end

  defp await_stream(%Session{} = session, state) do
    now = monotonic_ms()

    flush_deadline =
      min_deadline(
        TextBuffer.next_flush_deadline(state.text_buffer),
        TextBuffer.next_flush_deadline(state.note_buffer)
      )

    cond do
      now >= session.deadline ->
        timeout(session, state)

      is_integer(flush_deadline) and now >= flush_deadline ->
        flush_and_continue(session, state, now)

      true ->
        receive_for = min_deadline(session.deadline, flush_deadline) - now
        receive_stream(session, state, receive_for)
    end
  end

  defp flush_and_continue(%Session{} = session, state, now) do
    emit = session.context.emit

    case call_before(fn -> flush_due(state, emit, now) end, session.deadline) do
      {:ok, next} -> await_stream(session, next)
      {:error, error} -> halt_stream(session, state, error)
      :timeout -> timeout(session, state)
    end
  end

  defp receive_stream(%Session{} = session, state, receive_for) do
    tag = session.tag
    %StreamTask{pid: task_pid, ref: task_ref} = session.task

    receive do
      {^tag, :event, relay, acknowledgement, event} ->
        handle_relay_event(session, state, {relay, acknowledgement, event})

      {^tag, :stream_result, ^task_pid, result} ->
        Process.demonitor(task_ref, [:flush])
        finish_stream(result, session, state)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {:error, HTTP.error(:launch_failed, "Provider stream crashed: #{inspect(reason)}", false)}
    after
      max(receive_for, 0) -> await_stream(session, state)
    end
  end

  defp handle_relay_event(%Session{} = session, state, {relay, acknowledgement, event}) do
    result = call_before(fn -> handle_event(event, state, session.context) end, session.deadline)
    handle_relay_result(result, session, state, relay, acknowledgement)
  end

  defp handle_relay_result({:ok, {:cont, next}}, session, _state, relay, acknowledgement) do
    send(relay, {session.tag, acknowledgement, :cont})
    await_stream(session, next)
  end

  defp handle_relay_result(
         {:ok, {:halt, _next, error}},
         session,
         state,
         relay,
         acknowledgement
       ),
       do: halt_relay(session, state, relay, acknowledgement, error)

  defp handle_relay_result({:error, error}, session, state, relay, acknowledgement),
    do: halt_relay(session, state, relay, acknowledgement, error)

  defp handle_relay_result(:timeout, session, state, relay, acknowledgement),
    do: halt_relay(session, state, relay, acknowledgement, timeout_error(session.timeout))

  defp halt_relay(%Session{} = session, state, relay, acknowledgement, error) do
    send(relay, {session.tag, acknowledgement, {:halt, error}})
    halt_stream(session, state, error)
  end

  defp finish_stream({:ok, _final}, %Session{} = session, state) do
    with :ok <- valid_stream?(state),
         do: finish_valid_stream(session, state)
  end

  defp finish_stream({:error, error}, _session, state),
    do: {:error, replay_safe_failure(error, state)}

  defp finish_valid_stream(%Session{} = session, state) do
    emit = session.context.emit

    case call_before(fn -> flush_pending(state, emit) end, session.deadline) do
      {:ok, state} -> {:ok, response(state)}
      {:error, error} -> {:error, replay_safe_failure(error, state)}
      :timeout -> {:error, replay_safe_failure(timeout_error(session.timeout), state)}
    end
  end

  defp halt_stream(%Session{} = session, state, error) do
    remaining = max(session.deadline - monotonic_ms(), 0)
    await_or_stop_stream_task(session.task, session.tag, remaining)
    cancel_relays(session.tag, error)
    {:error, replay_safe_failure(error, state)}
  end

  defp timeout(%Session{} = session, state) do
    error = timeout_error(session.timeout)
    cancel_relays(session.tag, error)
    stop_stream_task(session.task)
    cancel_relays(session.tag, error)
    {:error, replay_safe_failure(error, state)}
  end

  defp await_or_stop_stream_task(%StreamTask{} = task, tag, timeout) do
    receive do
      {^tag, :stream_result, pid, _result} when pid == task.pid ->
        Process.demonitor(task.ref, [:flush])
        :ok

      {:DOWN, ref, :process, pid, _reason} when ref == task.ref and pid == task.pid ->
        :ok
    after
      timeout -> stop_stream_task(task)
    end
  end

  defp stop_stream_task(%StreamTask{} = task) do
    Process.exit(task.pid, :kill)

    receive do
      {:DOWN, ref, :process, pid, _reason} when ref == task.ref and pid == task.pid -> :ok
    after
      100 -> Process.demonitor(task.ref, [:flush])
    end
  end

  defp timeout_error(timeout),
    do: HTTP.error(:timeout, "Provider did not finish within #{timeout}ms", false)

  defp cancellation_error,
    do: HTTP.error(:request_cancelled, "Provider request was cancelled", false)

  defp min_deadline(nil, deadline), do: deadline
  defp min_deadline(deadline, nil), do: deadline
  defp min_deadline(deadline, flush_deadline), do: min(deadline, flush_deadline)

  defp cancel_relays(tag, error) do
    receive do
      {^tag, :event, relay, acknowledgement, _event} ->
        send(relay, {tag, acknowledgement, {:halt, error}})
        cancel_relays(tag, error)
    after
      0 -> :ok
    end
  end

  defp call_before(fun, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)

    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          exception ->
            {:error,
             HTTP.error(
               :launch_failed,
               "Provider callback crashed: #{Exception.message(exception)}",
               false
             )}
        catch
          kind, reason ->
            {:error,
             HTTP.error(
               :launch_failed,
               "Provider callback crashed: #{Exception.format_banner(kind, reason)}",
               false
             )}
        end
      end)

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error,
         HTTP.error(:launch_failed, "Provider callback exited: #{inspect(reason)}", false)}

      nil ->
        :timeout
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp handle_event({:partial, data}, state, %Context{emit: emit}) do
    bytes = state.bytes + byte_size(data)

    if bytes > state.max_bytes do
      {:halt, state,
       HTTP.error(:output_too_large, "Provider output exceeded #{state.max_bytes} bytes", false)}
    else
      {events, parser} = SSE.feed(state.parser, data)

      state =
        Enum.reduce(events, %{state | parser: parser, bytes: bytes}, fn event, acc ->
          apply_event(event, acc, emit)
        end)

      if state.protocol_error do
        {:error, error} = protocol_error()
        {:halt, state, error}
      else
        {:cont, state}
      end
    end
  end

  defp apply_event({:text, text}, state, emit) do
    state
    |> mark_output_observed(text)
    |> flush_note(emit)
    |> buffer_text(text, emit)
  end

  # Reasoning uses the same bounded batching as answer text. A segment keeps
  # its first frame sequence across batches so the transcript can join them.
  # Notes remain advisory and never set valid_output?.
  defp apply_event({:note, note}, state, emit) do
    state = state |> mark_output_observed(note) |> flush_pending(emit)
    {chunks, buffer} = TextBuffer.append(state.note_buffer, note)
    state |> Map.put(:note_buffer, buffer) |> emit_note_chunks(chunks, emit)
  end

  defp apply_event({:tool_started, tool, tool_state}, state, emit) do
    state
    |> Map.put(:output_observed?, true)
    |> flush_note(emit)
    |> put_in([:tool_calls, tool_call_id(tool_state)], unfinished_call(tool, tool_state))
  end

  defp apply_event({:tool_completed, tool, tool_state}, state, emit) do
    id = tool_call_id(tool_state)

    call = %{
      id: id,
      tool: tool,
      arguments_json: arguments_json(tool_state)
    }

    state
    |> Map.put(:output_observed?, true)
    |> flush_note(emit)
    |> put_in([:tool_calls, id], call)
    |> Map.put(:valid_output?, true)
  end

  defp apply_event({:usage, usage}, state, _emit),
    do: %{state | usage: usage, output_observed?: true}

  defp apply_event(:done, state, emit), do: flush_note(state, emit)

  defp apply_event({:protocol_error, reason}, state, _emit),
    do: %{state | protocol_error: reason}

  defp tool_call_id(tool_state) do
    id = tool_state["id"]

    if is_binary(id) and id != "" do
      id
    else
      "provider-tool-#{System.unique_integer([:positive])}"
    end
  end

  defp unfinished_call(tool, _tool_state), do: %{id: nil, tool: tool, arguments_json: nil}

  defp arguments_json(tool_state) do
    case tool_state["arguments"] do
      arguments when is_binary(arguments) -> arguments
      _other -> nil
    end
  end

  defp response(state) do
    tool_calls =
      state.tool_calls
      |> Enum.map(fn {_id, call} -> normalize_call(call) end)
      |> Enum.reject(&is_nil(&1.id))

    Response.new(text: state.text, tool_calls: tool_calls, usage: state.usage)
  end

  defp normalize_call(%{id: id, tool: tool, arguments_json: arguments_json})
       when is_binary(id) do
    arguments = decode_arguments(arguments_json)
    ToolCall.new(id, tool, arguments)
  end

  defp decode_arguments(arguments_json) when is_binary(arguments_json) do
    case Jason.decode(arguments_json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_arguments(_other), do: %{}

  defp flush_note(state, emit) do
    {chunks, buffer} = TextBuffer.flush(state.note_buffer)

    state
    |> Map.put(:note_buffer, buffer)
    |> emit_note_chunks(chunks, emit)
    |> Map.put(:note_segment_sequence, nil)
  end

  defp emit_note_chunks(state, chunks, emit) do
    Enum.reduce(chunks, state, fn note, state ->
      sequence = state.sequence + 1
      segment_sequence = state.note_segment_sequence || sequence
      frame = Frame.agent_note(sequence, note)
      :ok = emit.(%{frame | data: Map.put(frame.data, :segment_sequence, segment_sequence)})
      %{state | sequence: sequence, note_segment_sequence: segment_sequence}
    end)
  end

  defp buffer_text(state, "", _emit), do: state

  defp buffer_text(state, text, emit) do
    {chunks, buffer} = TextBuffer.append(state.text_buffer, text)

    state
    |> Map.put(:text_buffer, buffer)
    |> Map.put(:valid_output?, true)
    |> emit_text_chunks(chunks, emit)
  end

  defp flush_pending(state, emit) do
    {chunks, buffer} = TextBuffer.flush(state.text_buffer)
    state |> Map.put(:text_buffer, buffer) |> emit_text_chunks(chunks, emit)
  end

  defp flush_due(state, emit, now) do
    {chunks, buffer} = TextBuffer.flush_due(state.text_buffer, now)
    {notes, note_buffer} = TextBuffer.flush_due(state.note_buffer, now)

    state
    |> Map.put(:text_buffer, buffer)
    |> Map.put(:note_buffer, note_buffer)
    |> emit_text_chunks(chunks, emit)
    |> emit_note_chunks(notes, emit)
  end

  defp emit_text_chunks(state, chunks, emit),
    do: Enum.reduce(chunks, state, &emit_text_chunk(&2, emit, &1))

  defp emit_text_chunk(state, emit, text) do
    sequence = state.sequence + 1

    :ok =
      emit.(%Frame{sequence: sequence, kind: :text_delta, data: %{text: text}})

    %{state | sequence: sequence, text: state.text <> text}
  end

  defp initial_state(profile, request, config) do
    %{
      parser: SSE.new(),
      text_buffer:
        TextBuffer.new(
          chunk_bytes: config.chunk_bytes,
          chunk_latency_ms: config.chunk_latency_ms,
          flush_tail_on_size?: true
        ),
      sequence: request.resume_from,
      bytes: 0,
      max_bytes: profile.max_output_bytes,
      note_buffer:
        TextBuffer.new(
          chunk_bytes: config.chunk_bytes,
          chunk_latency_ms: config.chunk_latency_ms,
          flush_tail_on_size?: true
        ),
      note_segment_sequence: nil,
      usage: nil,
      protocol_error: nil,
      valid_output?: false,
      output_observed?: false,
      text: "",
      tool_calls: %{}
    }
  end

  defp valid_stream?(%{protocol_error: nil, parser: parser, valid_output?: true}) do
    case SSE.finish(parser) do
      :ok -> :ok
      {:error, _reason} -> protocol_error()
    end
  end

  defp valid_stream?(_state), do: protocol_error()

  defp protocol_error,
    do: {:error, HTTP.error(:protocol_error, @protocol_error_message, false)}

  defp mark_output_observed(state, value) when is_binary(value) and value != "",
    do: %{state | output_observed?: true}

  defp mark_output_observed(state, _value), do: state

  defp replay_safe_failure(%ReyCode.Failure{retryable?: true} = error, %{
         output_observed?: true
       }) do
    %{
      error
      | retryable?: false,
        message: error.message <> "; automatic retry stopped after provider output was observed"
    }
  end

  defp replay_safe_failure(error, _state), do: error

  defp authorization(nil), do: []
  defp authorization(key), do: [{"Authorization", "Bearer " <> key}]

  defp base_url(profile), do: String.trim_trailing(profile.base_url, "/")
end
