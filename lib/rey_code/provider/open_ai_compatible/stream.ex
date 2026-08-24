defmodule ReyCode.Provider.OpenAICompatible.Stream do
  @moduledoc "Owns one bounded provider stream from transport launch through normalized response."

  alias ReyCode.Provider.{Frame, Response, TextBuffer, ToolCall}
  alias ReyCode.Provider.OpenAICompatible.{HTTP, SSE}
  alias ReyCode.RuntimeConfig

  @default_chunk_bytes 8_192
  @default_chunk_latency_ms 50
  @protocol_error_message "Provider returned an invalid streaming response"

  defmodule Context do
    @moduledoc false

    @enforce_keys [:transport, :profile, :key, :request, :body, :emit]
    defstruct [:transport, :profile, :key, :request, :body, :emit, :config]
  end

  defmodule StreamTask do
    @moduledoc false

    @enforce_keys [:pid, :ref]
    defstruct [:pid, :ref]
  end

  def run(%Context{profile: profile} = context) do
    timeout = profile.request_timeout_ms
    owner = Process.alias()
    tag = make_ref()
    deadline = monotonic_ms() + timeout
    state = initial_state(profile, context.request, context.config)
    task = start_stream_task(context, owner, tag)

    try do
      await_stream(task, tag, context, state, deadline, timeout)
    rescue
      exception ->
        stop_stream_task(task)
        cancel_relays(tag, cancellation_error())

        {:error,
         HTTP.error(
           "launch_failed",
           "Provider stream crashed: #{Exception.message(exception)}",
           false
         )}
    catch
      kind, reason ->
        stop_stream_task(task)
        cancel_relays(tag, cancellation_error())

        {:error,
         HTTP.error(
           "launch_failed",
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

      {:DOWN, ^monitor, :process, ^transport_owner, _reason} ->
        {:halt, acc, cancellation_error()}
    end
  end

  defp await_stream(task, tag, context, state, deadline, timeout) do
    now = monotonic_ms()
    flush_deadline = TextBuffer.next_flush_deadline(state.text_buffer)

    cond do
      now >= deadline ->
        timeout(task, tag, timeout)

      is_integer(flush_deadline) and now >= flush_deadline ->
        flush_and_continue(task, tag, context, state, deadline, timeout, now)

      true ->
        receive_for = min_deadline(deadline, flush_deadline) - now
        receive_stream(task, tag, context, state, deadline, timeout, receive_for)
    end
  end

  defp flush_and_continue(task, tag, context, state, deadline, timeout, now) do
    case call_before(fn -> flush_due(state, context.emit, now) end, deadline) do
      {:ok, next} -> await_stream(task, tag, context, next, deadline, timeout)
      {:error, error} -> halt_stream(task, tag, error, deadline)
      :timeout -> timeout(task, tag, timeout)
    end
  end

  defp receive_stream(task, tag, context, state, deadline, timeout, receive_for) do
    %StreamTask{pid: task_pid, ref: task_ref} = task

    receive do
      {^tag, :event, relay, acknowledgement, event} ->
        handle_relay_event(
          task,
          tag,
          context,
          state,
          deadline,
          timeout,
          {relay, acknowledgement, event}
        )

      {^tag, :stream_result, ^task_pid, result} ->
        Process.demonitor(task.ref, [:flush])
        finish_stream(result, state, context.emit, deadline, timeout)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {:error,
         HTTP.error("launch_failed", "Provider stream crashed: #{inspect(reason)}", false)}
    after
      max(receive_for, 0) -> await_stream(task, tag, context, state, deadline, timeout)
    end
  end

  defp handle_relay_event(
         task,
         tag,
         context,
         state,
         deadline,
         timeout,
         {relay, acknowledgement, event}
       ) do
    result = call_before(fn -> handle_event(event, state, context) end, deadline)
    handle_relay_result(result, task, tag, context, deadline, timeout, relay, acknowledgement)
  end

  defp handle_relay_result(
         {:ok, {:cont, next}},
         task,
         tag,
         context,
         deadline,
         timeout,
         relay,
         acknowledgement
       ) do
    send(relay, {tag, acknowledgement, :cont})
    await_stream(task, tag, context, next, deadline, timeout)
  end

  defp handle_relay_result(
         {:ok, {:halt, _next, error}},
         task,
         tag,
         _context,
         deadline,
         _timeout,
         relay,
         acknowledgement
       ),
       do: halt_relay(task, tag, deadline, relay, acknowledgement, error)

  defp handle_relay_result(
         {:error, error},
         task,
         tag,
         _context,
         deadline,
         _timeout,
         relay,
         acknowledgement
       ),
       do: halt_relay(task, tag, deadline, relay, acknowledgement, error)

  defp handle_relay_result(
         :timeout,
         task,
         tag,
         _context,
         deadline,
         timeout,
         relay,
         acknowledgement
       ),
       do: halt_relay(task, tag, deadline, relay, acknowledgement, timeout_error(timeout))

  defp halt_relay(task, tag, deadline, relay, acknowledgement, error) do
    send(relay, {tag, acknowledgement, {:halt, error}})
    halt_stream(task, tag, error, deadline)
  end

  defp finish_stream({:ok, _final}, state, emit, deadline, timeout) do
    with :ok <- valid_stream?(state),
         do: finish_valid_stream(state, emit, deadline, timeout)
  end

  defp finish_stream({:error, error}, _state, _emit, _deadline, _timeout), do: {:error, error}

  defp finish_valid_stream(state, emit, deadline, timeout) do
    case call_before(fn -> flush_pending(state, emit) end, deadline) do
      {:ok, state} -> {:ok, response(state)}
      {:error, error} -> {:error, error}
      :timeout -> {:error, timeout_error(timeout)}
    end
  end

  defp halt_stream(task, tag, error, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)
    await_or_stop_stream_task(task, tag, remaining)
    cancel_relays(tag, error)
    {:error, error}
  end

  defp timeout(task, tag, timeout) do
    error = timeout_error(timeout)
    cancel_relays(tag, error)
    stop_stream_task(task)
    cancel_relays(tag, error)
    {:error, error}
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
    do: HTTP.error("timeout", "Provider did not finish within #{timeout}ms", true)

  defp cancellation_error,
    do: HTTP.error("request_cancelled", "Provider request was cancelled", false)

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
               "launch_failed",
               "Provider callback crashed: #{Exception.message(exception)}",
               false
             )}
        catch
          kind, reason ->
            {:error,
             HTTP.error(
               "launch_failed",
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
         HTTP.error("launch_failed", "Provider callback exited: #{inspect(reason)}", false)}

      nil ->
        :timeout
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp handle_event({:partial, data}, state, %Context{emit: emit}) do
    bytes = state.bytes + byte_size(data)

    if bytes > state.max_bytes do
      {:halt, state,
       HTTP.error("output_too_large", "Provider output exceeded #{state.max_bytes} bytes", false)}
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

  defp apply_event({:text, text}, state, emit), do: buffer_text(state, text, emit)

  defp apply_event({:tool_started, tool, tool_state}, state, _emit),
    do: put_in(state.tool_calls[tool_call_id(tool_state)], unfinished_call(tool, tool_state))

  defp apply_event({:tool_completed, tool, tool_state}, state, _emit) do
    id = tool_call_id(tool_state)

    call = %{
      id: id,
      tool: tool,
      arguments_json: arguments_json(tool_state)
    }

    state
    |> put_in([:tool_calls, id], call)
    |> Map.put(:valid_output?, true)
  end

  defp apply_event({:usage, usage}, state, _emit), do: %{state | usage: usage}
  defp apply_event(:done, state, _emit), do: state

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
    state |> Map.put(:text_buffer, buffer) |> emit_text_chunks(chunks, emit)
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
          chunk_bytes:
            RuntimeConfig.policy(
              config,
              :openai_compatible_chunk_bytes,
              @default_chunk_bytes
            ),
          chunk_latency_ms:
            RuntimeConfig.policy(
              config,
              :openai_compatible_chunk_latency_ms,
              @default_chunk_latency_ms
            ),
          flush_tail_on_size?: true
        ),
      sequence: request.resume_from,
      bytes: 0,
      max_bytes: profile.max_output_bytes,
      usage: nil,
      protocol_error: nil,
      valid_output?: false,
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
    do: {:error, HTTP.error("protocol_error", @protocol_error_message, false)}

  defp authorization(key), do: [{"Authorization", "Bearer " <> key}]

  defp base_url(profile), do: String.trim_trailing(profile.base_url, "/")
end
