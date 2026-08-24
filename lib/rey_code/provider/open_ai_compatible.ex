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

  alias ReyCode.Failure
  alias ReyCode.Provider.{Frame, Request, Response, Runtime}
  alias ReyCode.Provider.OpenAICompatible.{HTTP, Profile, Stream}
  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.OpenAICompatible, as: OpenAIPolicy
  alias ReyCode.ToolRegistry

  @behaviour ReyCode.Provider

  @default_model_response_bytes 1_000_000

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
  @spec stream(Runtime.t(), Request.t(), (Frame.t() -> :ok)) ::
          {:ok, Response.t()} | {:error, Failure.t()}
  def stream(%Runtime{provider_id: provider_id, config: %OpenAIPolicy{} = policy}, request, emit) do
    transport = transport(policy)

    with {:ok, profile} <- Profile.fetch(provider_id, policy),
         {:ok, key} <- fetch_key(profile),
         {:ok, body} <- build_body(request, profile) do
      Stream.run(%Stream.Context{
        transport: transport,
        profile: profile,
        key: key,
        request: request,
        body: body,
        emit: emit,
        config: policy
      })
    end
  end

  defp fetch_models(profile, opts) do
    policy = Keyword.get_lazy(opts, :policy, fn -> RuntimeConfig.fresh().open_ai end)
    transport = Keyword.get(opts, :transport) || transport(policy)
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
        :prompt_too_large,
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
       HTTP.error(:missing_credentials, "Set #{profile.key_env} to use #{profile.name}", false)}
    else
      {:ok, System.get_env(profile.key_env)}
    end
  end

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
