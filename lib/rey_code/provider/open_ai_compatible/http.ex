defmodule ReyCode.Provider.OpenAICompatible.HTTP do
  @moduledoc false

  alias ReyCode.Provider.OpenAICompatible.HTTP

  @type method :: :get | :post
  @type url :: binary()
  @type headers :: [{binary(), binary()}]
  @type event :: {:partial, binary()}
  @type on_event :: (event, term() -> {:cont, term()} | {:halt, term(), map()})
  @type final :: %{status: non_neg_integer(), headers: headers()}

  @callback start(method, url, headers, body :: binary() | nil, keyword()) ::
              {:ok, term()} | {:error, map()}

  @callback collect(term(), on_event, term()) :: {:ok, term(), final} | {:error, map()}

  @spec error(String.t(), String.t(), boolean()) :: map()
  def error(category, message, retryable) do
    %{"category" => category, "message" => message, "retryable" => retryable}
  end

  @spec status_error(non_neg_integer(), binary()) :: map()
  def status_error(status, body) do
    {category, message, retryable} = classify_status(status, body)
    HTTP.error(category, message, retryable)
  end

  defp classify_status(status, body) do
    cond do
      status in [401, 403] ->
        {"authentication_failed", parsed_message(body, "Authentication failed (#{status})"),
         false}

      status == 429 ->
        {"rate_limited", parsed_message(body, "Rate limited (429)"), true}

      status in 500..599 ->
        {"server_error", parsed_message(body, "Provider error (#{status})"), true}

      true ->
        {"request_failed", parsed_message(body, "Request failed (#{status})"), false}
    end
  end

  defp parsed_message(body, fallback) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      _ -> fallback
    end
  end
end
