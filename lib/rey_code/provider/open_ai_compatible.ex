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

  defp run(%StreamContext{profile: profile, emit: emit} = context) do
    timeout = profile.request_timeout_ms

    task = Task.async(fn -> stream_task(context) end)

    case Task.yield(task, timeout) do
      {:ok, {:ok, state}} ->
        state = flush_pending(state, emit)
        {:ok, response(state)}

      {:ok, {:error, _} = error} ->
        error

      {:exit, reason} ->
        _ = Task.shutdown(task, :brutal_kill)

        {:error,
         HTTP.error("launch_failed", "Provider stream crashed: #{inspect(reason)}", false)}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, HTTP.error("timeout", "Provider did not finish within #{timeout}ms", true)}
    end
  end

  defp stream_task(%StreamContext{} = context) do
    stream_task(context, initial_state(context.profile, context.request))
  end

  defp stream_task(%StreamContext{} = context, state) do
    %{transport: transport, profile: profile, key: key, body: body} = context
    url = base_url(profile) <> "/chat/completions"
    headers = authorization(key) ++ [{"Accept", "text/event-stream"}]
    opts = [timeout: profile.request_timeout_ms]

    with {:ok, ref} <- transport.start(url, headers, body, opts),
         {:ok, state, _final} <-
           transport.collect(
             ref,
             &handle_event(&1, &2, context),
             state
           ) do
      {:ok, state}
    end
  end

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

      {:cont, state}
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

    put_in(state.tool_calls[id], call)
  end

  defp apply_event({:usage, usage}, state, _emit), do: %{state | usage: usage}
  defp apply_event(:done, state, _emit), do: state
  defp apply_event(:ignore, state, _emit), do: state

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
    state |> Map.put(:text_buffer, buffer) |> emit_text_chunks(chunks, emit)
  end

  defp flush_pending(state, emit) do
    {chunks, buffer} = TextBuffer.flush(state.text_buffer)
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
      protocol_activity?: false,
      text: "",
      tool_calls: %{}
    }
  end

  defp fetch_models(profile, opts) do
    transport = Keyword.get(opts, :transport, transport())
    url = base_url(profile) <> "/models"
    headers = authorization(System.get_env(profile.key_env)) ++ [{"Accept", "application/json"}]
    opts_list = [timeout: Keyword.get(opts, :timeout, profile.request_timeout_ms)]

    with {:ok, ref} <- transport.start(url, headers, "", opts_list),
         {:ok, _acc, %{status: status, body: body}} when status in 200..299 <-
           transport.collect(ref, &ignore_event/2, nil) do
      {:ok, parse_models(body)}
    else
      {:ok, _acc, %{status: status, body: body}} ->
        {:error, "model list request failed (HTTP #{status}): #{truncate(body, 200)}"}

      {:error, %{"message" => message}} ->
        {:error, message}

      {:error, reason} ->
        {:error, "model list request failed: #{inspect(reason)}"}
    end
  end

  defp ignore_event(_event, acc), do: {:cont, acc}

  defp parse_models(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) ->
        models
        |> Enum.map(& &1["id"])
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
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
    Application.get_env(:rey_code, :openai_compatible_transport, OpenAICompatible.HTTPC)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  defp truncate(value, limit) when byte_size(value) <= limit, do: value
  defp truncate(value, limit), do: TextBuffer.truncate_utf8(value, limit)
end
