defmodule ReyCode.Provider.OpenAICompatible do
  @moduledoc """
  A streaming provider for OpenAI-compatible chat completion APIs.

  Each profile (DeepSeek by default) is described by a base URL and an
  environment variable that holds the API key. The key is read from the
  environment at invocation time and is never persisted in events or in the
  catalog snapshot. OpenAI-compatible providers support streaming text, usage and
  tool-call lifecycle frames while keeping prompt/workspace handling separate.
  """

  alias ReyCode.Provider.{Frame, Request, Runtime, TextBuffer}
  alias ReyCode.Provider.OpenAICompatible.{HTTP, Profile, SSE}

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

  @doc "Streams a chat completion from the runtime's OpenAI-compatible provider."
  @impl true
  @spec stream(Runtime.t(), Request.t(), ReyCode.Provider.emit()) ::
          {:ok, map()} | {:error, map()}
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
        flush_pending(state, emit)
        {:ok, %{usage: state.usage}}

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

  defp stream_task(%StreamContext{request: request} = context) do
    %{transport: transport, profile: profile, key: key, body: body} = context
    url = base_url(profile) <> "/chat/completions"
    headers = authorization(key) ++ [{"Accept", "text/event-stream"}]
    opts = [timeout: profile.request_timeout_ms]

    with {:ok, ref} <- transport.start(url, headers, body, opts),
         {:ok, state, _final} <-
           transport.collect(
             ref,
             &handle_event(&1, &2, context),
             initial_state(profile, request)
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

  defp apply_event({kind, tool, tool_state}, state_acc, emit)
       when kind in [:tool_started, :tool_completed] do
    emit_tool_event(state_acc, emit, kind, tool, tool_state)
  end

  defp apply_event({:usage, usage}, state, _emit), do: %{state | usage: usage}
  defp apply_event(:done, state, _emit), do: state
  defp apply_event(:ignore, state, _emit), do: state

  defp emit_tool_event(state, emit, kind, tool, tool_state) do
    sequence = state.sequence + 1
    :ok = emit.(%Frame{sequence: sequence, kind: kind, data: %{tool: tool, state: tool_state}})
    %{state | sequence: sequence}
  end

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
    :ok = emit.(%Frame{sequence: sequence, kind: :text_delta, data: %{text: text}})
    %{state | sequence: sequence, protocol_activity?: true}
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
      protocol_activity?: false
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
    body =
      %{
        "model" => request.participant.model,
        "stream" => true,
        "messages" => chat_messages(request),
        "stream_options" => %{"include_usage" => true}
      }
      |> Jason.encode!()

    if byte_size(body) > profile.max_prompt_bytes do
      {:error,
       HTTP.error(
         "prompt_too_large",
         "Provider prompt is #{byte_size(body)} bytes; maximum is #{profile.max_prompt_bytes} bytes",
         false
       )}
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
      Enum.map(request.messages, fn
        %{role: :user, content: content} -> %{"role" => "user", "content" => content}
        %{role: :assistant, content: content} -> %{"role" => "assistant", "content" => content}
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
