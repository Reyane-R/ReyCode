defmodule ReyCode.Provider.OpenAICompatible do
  @moduledoc """
  Streams OpenAI-compatible chat completion APIs.

  Each `stream/3` call performs exactly one model round: it emits streaming
  text frames and returns the round's normalized response, including any tool
  calls. Follow-up rounds are driven by ReyCode's agent loop, which supplies
  the accumulated tool results through the request conversation.
  """

  alias ReyCode.Capabilities
  alias ReyCode.Failure
  alias ReyCode.Provider.{Frame, Request, Response, Runtime}
  alias ReyCode.Provider.OpenAICompatible.{HTTP, Profile, RequestShape, Stream}
  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.OpenAICompatible, as: OpenAIPolicy
  alias ReyCode.RuntimeConfig.Schema
  alias ReyCode.ToolRegistry

  @behaviour ReyCode.Provider

  @default_model_response_bytes 1_000_000

  @doc "Discovers one profile's availability and models without exposing its key."
  @spec discover(Profile.t(), keyword()) :: {:ok, map()}
  def discover(profile, opts \\ []) do
    if profile.require_key == false or not blank?(System.get_env(profile.key_env)) do
      case fetch_models(profile, opts) do
        {:ok, models} ->
          {:ok,
           %{
             status: :configured,
             models: models,
             credential_count: credential_count(profile),
             error: nil
           }}

        {:error, message} ->
          {:ok,
           %{
             status: :error,
             models: [],
             credential_count: credential_count(profile),
             error: message
           }}
      end
    else
      {:ok, %{status: :available, models: [], credential_count: 0, error: nil}}
    end
  end

  @doc "Streams one chat-completion round from the runtime's OpenAI-compatible provider."
  @spec stream(Runtime.t(), Request.t(), (Frame.t() -> :ok)) ::
          {:ok, Response.t()} | {:error, Failure.t()}
  def stream(%Runtime{provider_id: provider_id, config: %OpenAIPolicy{} = policy}, request, emit) do
    transport = transport(policy)

    with {:ok, profile} <- Profile.fetch(provider_id, policy),
         {:ok, key} <- fetch_key(profile) do
      context = %Stream.Context{
        transport: transport,
        profile: profile,
        key: key,
        request: request,
        emit: emit,
        config: policy
      }

      run_stream(context, initial_shape(profile))
    end
  end

  # Strict servers may reject `stream_options` or `tools` with HTTP 400 before
  # any side effect. The ladder retries once without `stream_options`; if the
  # server still refuses while tools were offered, the invocation fails loudly
  # with `tool_calls_unsupported` instead of degrading to a silent chat-only
  # round. Non-400 failures keep their existing semantics. A shape that worked
  # is remembered via RequestShape for later rounds and invocations.
  defp run_stream(%Stream.Context{} = context, shape) do
    with {:ok, body} <- build_body(context.request, context.profile, shape) do
      case Stream.run(%{context | body: body}) do
        {:ok, response} ->
          remember_downgrade(context.profile, shape)
          {:ok, response}

        {:error, %Failure{category: :request_failed, cause: 400} = error} ->
          downgrade(context, shape, error)

        other ->
          other
      end
    end
  end

  defp downgrade(%Stream.Context{} = context, %{stream_options?: true}, _error),
    do: run_stream(context, %{default_shape(context.profile) | stream_options?: false})

  defp downgrade(%Stream.Context{profile: profile}, %{tools?: true}, error),
    do: {:error, tool_calls_unsupported(profile, error)}

  # Neither optional feature was on the wire, so the rejection is not about
  # capabilities; surface it unchanged.
  defp downgrade(_context, _shape, error), do: {:error, error}

  # A remembered shape only ever suppresses features the server rejected, so
  # it intersects with today's profile: an explicit pin always wins over the
  # memory of an older downgrade.
  defp initial_shape(profile) do
    default = default_shape(profile)

    case RequestShape.get(profile) do
      nil ->
        default

      remembered ->
        %{
          tools?: default.tools? and remembered.tools?,
          stream_options?: default.stream_options? and remembered.stream_options?
        }
    end
  end

  defp default_shape(profile),
    do: %{tools?: profile.supports_tools, stream_options?: profile.supports_stream_options}

  defp remember_downgrade(profile, shape) do
    if shape != default_shape(profile), do: RequestShape.put(profile.id, shape)

    :ok
  end

  defp tool_calls_unsupported(profile, original) do
    pin = Schema.capability_environment_name(profile.id, :supports_tools) <> "=false"

    HTTP.error(
      :tool_calls_unsupported,
      "#{profile.name} rejected tool calls (#{original.message}). " <>
        "Set supports_tools: false or #{pin} to send requests without tools explicitly.",
      false
    )
  end

  defp fetch_models(profile, opts) do
    policy = Keyword.get_lazy(opts, :policy, fn -> RuntimeConfig.fresh().open_ai end)
    transport = Keyword.get(opts, :transport) || transport(policy)
    url = base_url(profile) <> "/models"
    headers = authorization(api_key(profile)) ++ [{"Accept", "application/json"}]
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

      {:error, %Failure{message: message}} ->
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
       HTTP.error(:response_too_large, "Model response exceeded #{max_bytes} bytes", false)}
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

  defp build_body(request, profile, shape) do
    request_body(profile, request.participant.model, chat_messages(request), shape)
  end

  # Capability flags control which optional features appear on the wire; a
  # pinned strict-server profile omits them from the first attempt.
  defp request_body(profile, model, messages, shape) do
    body =
      %{"model" => model, "stream" => true, "messages" => messages}
      |> maybe_put("tools", tool_definitions(), shape.tools?)
      |> maybe_put("stream_options", %{"include_usage" => true}, shape.stream_options?)
      |> Jason.encode!()

    if byte_size(body) > profile.max_prompt_bytes do
      HTTP.error(
        :prompt_too_large,
        "Provider prompt is #{byte_size(body)} bytes; maximum is #{profile.max_prompt_bytes} bytes",
        false
      )
      |> then(&{:error, &1})
    else
      {:ok, body}
    end
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp chat_messages(request) do
    system =
      [
        request.system_prompt,
        Capabilities.prompt_hint(),
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
    Enum.map(ToolRegistry.wire_tool_names(), fn name ->
      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => wire_tool_description(name),
          "parameters" => %{
            "type" => "object",
            "additionalProperties" => true,
            "properties" => tool_parameters(name)
          }
        }
      }
    end)
  end

  defp wire_tool_description("spawn_task") do
    "Delegate a bounded subtask to a named task agent. The parent pauses until " <>
      "the child reports; the report returns as this tool's result. " <>
      "Arguments: {\"agent\": <exact task participant name>, \"brief\": <instruction>}"
  end

  defp wire_tool_description(name), do: "ReyCode workspace tool #{name}"

  defp tool_parameters("spawn_task") do
    %{
      "agent" => %{"type" => "string", "description" => "Exact task participant name"},
      "brief" => %{"type" => "string", "description" => "Self-contained task instruction"}
    }
  end

  defp tool_parameters(_name), do: %{}

  defp fetch_key(%Profile{require_key: false}), do: {:ok, nil}

  defp fetch_key(profile) do
    if blank?(System.get_env(profile.key_env)) do
      {:error,
       HTTP.error(:missing_credentials, "Set #{profile.key_env} to use #{profile.name}", false)}
    else
      {:ok, System.get_env(profile.key_env)}
    end
  end

  defp api_key(%Profile{require_key: false}), do: nil
  defp api_key(profile), do: System.get_env(profile.key_env)

  defp credential_count(%Profile{require_key: false}), do: 0
  defp credential_count(_profile), do: 1

  defp authorization(nil), do: []
  defp authorization(key), do: [{"Authorization", "Bearer " <> key}]

  defp base_url(profile), do: String.trim_trailing(profile.base_url, "/")

  defp transport(policy)
  defp transport(%OpenAIPolicy{transport: nil}), do: ReyCode.Provider.OpenAICompatible.HTTPC
  defp transport(%OpenAIPolicy{transport: transport}), do: transport

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
