defmodule ReyCode.Provider.OpenAICompatible do
  @moduledoc """
  A streaming provider for OpenAI-compatible chat completion APIs.

  Each profile (DeepSeek by default) is described by a base URL and an
  environment variable that holds the API key. The key is read from the
  environment at invocation time and is never persisted in events or in the
  catalog snapshot.

  Each `stream/3` call performs exactly one model round: it emits streaming
  text frames and returns the round's normalized response, including any tool
  calls. Follow-up rounds are driven by ReyCode's agent loop, which supplies
  the accumulated tool results through the request conversation.
  """

  alias ReyCode.Provider.{Frame, Request, Response, Runtime, TextBuffer, ToolCall}
  alias ReyCode.Provider.OpenAICompatible.{HTTP, Profile, SSE}
  alias ReyCode.ToolRegistry

  @behaviour ReyCode.Provider

  defmodule StreamContext do
    @moduledoc false

    @enforce_keys [:transport, :profile, :key, :request, :body, :emit]
    defstruct [:transport, :profile, :key, :request, :body, :emit]
  end

  @default_chunk_bytes 8_192
  @default_chunk_latency_ms 50
  @default_model_response_bytes 1_000_000
  @protocol_error_message "Provider returned an invalid streaming response"

  @doc "Discovers one profile's availability and models without exposing its key."
  @spec discover(Profile.t(), keyword()) :: {:ok, map()}
  def discover(profile, opts \\ []) do
    if blank?(System.get_env(profile.key_env)) do
      {:ok, %{status: :available, models: [], credential_count: 0, error: nil}}
    else
      case fetch_models(profile, opts) do
        {:ok, models} ->
          {:ok, %{status: :configured, models: models, credential_count: 1, error: nil}}

        {:error, message} ->
          {:ok, %{status: :error, models: [], credential_count: 1, error: message}}
      end
    end
  end

  @doc "Streams one chat-completion round from the runtime's OpenAI-compatible provider."
  @impl true
  @spec stream(Runtime.t(), Request.t(), (Frame.t() -> :ok)) ::
          {:ok, Response.t()} | {:error, map()}
  def stream(%Runtime{provider_id: provider_id}, request, emit) do
    transport = transport()

    with {:ok, profile} <- Profile.fetch(provider_id),
         {:ok, key} <- fetch_key(profile),
         {:ok, body} <- build_body(request, profile) do
      run(%StreamContext{
        transport: transport,
        profile: profile,
        key: key,
        request: request,
        body: body,
        emit: emit
      })
    end
  end

  defp run(%StreamContext{profile: profile} = context) do
    timeout = profile.request_timeout_ms
    owner = Process.alias()
    tag = make_ref()
    deadline = monotonic_ms() + timeout
    state = initial_state(profile, context.request)
    task = Task.async(fn -> stream_task(context, owner, tag) end)

    try do
      await_stream(task, tag, context, state, deadline, timeout)
    rescue
      exception ->
        Task.shutdown(task, :brutal_kill)
        cancel_relays(tag, cancellation_error())

        {:error,
         HTTP.error(
           "launch_failed",
           "Provider stream crashed: #{Exception.message(exception)}",
           false
         )}
    catch
      kind, reason ->
        Task.shutdown(task, :brutal_kill)
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

  defp stream_task(%StreamContext{} = context, owner, tag) do
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

      {reference, result} when reference == task.ref ->
        Process.demonitor(task.ref, [:flush])
        finish_stream(result, state, context.emit, deadline, timeout)

      {:DOWN, reference, :process, _pid, reason} when reference == task.ref ->
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
    _ = Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill)
    cancel_relays(tag, error)
    {:error, error}
  end

  defp timeout(task, tag, timeout) do
    error = timeout_error(timeout)
    cancel_relays(tag, error)
    _ = Task.shutdown(task, :brutal_kill)
    cancel_relays(tag, error)
    {:error, error}
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

  defp handle_event({:partial, data}, state, %StreamContext{emit: emit}) do
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

  defp initial_state(profile, request) do
    %{
      parser: SSE.new(),
      text_buffer:
        TextBuffer.new(
          chunk_bytes:
            Application.get_env(:rey_code, :openai_compatible_chunk_bytes, @default_chunk_bytes),
          chunk_latency_ms:
            Application.get_env(
              :rey_code,
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

  defp fetch_models(profile, opts) do
    transport = Keyword.get(opts, :transport, transport())
    url = base_url(profile) <> "/models"
    headers = authorization(System.get_env(profile.key_env)) ++ [{"Accept", "application/json"}]
    opts_list = [timeout: Keyword.get(opts, :timeout, profile.request_timeout_ms)]
    max_bytes = Keyword.get(opts, :max_response_bytes, @default_model_response_bytes)

    with {:ok, ref} <- transport.start(:get, url, headers, nil, opts_list),
         {:ok, body, %{status: status}} when status in 200..299 <-
           transport.collect(ref, &collect_model_bytes(&1, &2, max_bytes), ""),
         {:ok, models} <- parse_models(body) do
      {:ok, models}
    else
      {:ok, _body, %{status: status}} ->
        {:error, "model list request returned HTTP status #{inspect(status)}"}

      {:error, %{"message" => message}} ->
        {:error, message}

      {:error, reason} ->
        {:error, "model list request failed: #{inspect(reason)}"}

      other ->
        {:error, "model list request returned an invalid result: #{inspect(other)}"}
    end
  end

  defp collect_model_bytes({:partial, data}, body, max_bytes) do
    if byte_size(body) + byte_size(data) > max_bytes do
      {:halt, body,
       HTTP.error("response_too_large", "Model response exceeded #{max_bytes} bytes", false)}
    else
      {:cont, body <> data}
    end
  end

  defp parse_models(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) ->
        parse_model_entries(models)

      {:ok, _invalid} ->
        {:error, "model list response has an invalid schema"}

      {:error, _reason} ->
        {:error, "model list response is not valid JSON"}
    end
  end

  defp parse_model_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      %{"id" => id}, {:ok, acc} when is_binary(id) and id != "" ->
        {:cont, {:ok, [id | acc]}}

      _invalid, _acc ->
        {:halt, {:error, "model list response has an invalid schema"}}
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      {:error, _message} = error -> error
    end
  end

  defp build_body(request, profile) do
    request_body(profile, request.participant.model, chat_messages(request))
  end

  defp request_body(profile, model, messages) do
    body =
      %{
        "model" => model,
        "stream" => true,
        "messages" => messages,
        "tools" => tool_definitions(),
        "stream_options" => %{"include_usage" => true}
      }
      |> Jason.encode!()

    if byte_size(body) > profile.max_prompt_bytes do
      HTTP.error(
        "prompt_too_large",
        "Provider prompt is #{byte_size(body)} bytes; maximum is #{profile.max_prompt_bytes} bytes",
        false
      )
      |> then(&{:error, &1})
    else
      {:ok, body}
    end
  end

  defp chat_messages(request) do
    system =
      [
        request.system_prompt,
        "You are responding as #{request.participant.name} with the perspective: #{request.participant.perspective}.",
        "Respond to the latest user request."
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    [%{"role" => "system", "content" => system}] ++
      Enum.map(request.messages, &wire_message/1)
  end

  defp wire_message(%{role: :user, content: content}),
    do: %{"role" => "user", "content" => content}

  defp wire_message(%{role: :assistant, tool_calls: [_ | _]} = message) do
    %{
      "role" => "assistant",
      "content" => message.content,
      "tool_calls" => Enum.map(message.tool_calls, &wire_tool_call/1)
    }
  end

  defp wire_message(%{role: :assistant, content: content}),
    do: %{"role" => "assistant", "content" => content}

  defp wire_message(%{role: :tool} = message) do
    %{
      "role" => "tool",
      "tool_call_id" => message.tool_call_id,
      "content" => message.content
    }
  end

  defp wire_tool_call(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.tool, "arguments" => Jason.encode!(call.arguments || %{})}
    }
  end

  defp tool_definitions do
    Enum.map(ToolRegistry.tool_names(), fn name ->
      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => "ReyCode workspace tool #{name}",
          "parameters" => %{
            "type" => "object",
            "additionalProperties" => true,
            "properties" => %{}
          }
        }
      }
    end)
  end

  defp fetch_key(profile) do
    if blank?(System.get_env(profile.key_env)) do
      {:error,
       HTTP.error("missing_credentials", "Set #{profile.key_env} to use #{profile.name}", false)}
    else
      {:ok, System.get_env(profile.key_env)}
    end
  end

  defp authorization(key), do: [{"Authorization", "Bearer " <> key}]

  defp base_url(profile), do: String.trim_trailing(profile.base_url, "/")

  defp transport do
    Application.get_env(
      :rey_code,
      :openai_compatible_transport,
      ReyCode.Provider.OpenAICompatible.HTTPC
    )
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
