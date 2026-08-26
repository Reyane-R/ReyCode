defmodule ReyCode.Provider.OpenAICompatible.HTTP do
  @moduledoc false

  alias ReyCode.Failure

  @type method :: :get | :post
  @type url :: binary()
  @type headers :: [{binary(), binary()}]
  @type event :: {:partial, binary()}
  @type on_event :: (event, term() -> {:cont, term()} | {:halt, term(), Failure.t()})
  @type final :: %{status: non_neg_integer(), headers: headers()}

  @callback start(method, url, headers, body :: binary() | nil, keyword()) ::
              {:ok, term()} | {:error, Failure.t()}

  @callback collect(term(), on_event, term()) ::
              {:ok, term(), final} | {:error, Failure.t()}

  @spec error(atom(), String.t(), boolean()) :: Failure.t()
  def error(category, message, retryable), do: Failure.new(category, message, retryable)

  # The status rides in `cause` so callers can distinguish downgrade-worthy
  # HTTP 400 rejections from other request failures without parsing messages;
  # wire serialization drops it.
  @spec status_error(non_neg_integer(), binary()) :: Failure.t()
  def status_error(status, body) do
    {category, message, retryable} = classify_status(status, body)
    Failure.new(category, message, retryable, status)
  end

  defp classify_status(status, body) do
    cond do
      status in [401, 403] ->
        {:authentication_failed, parsed_message(body, "Authentication failed (#{status})"), false}

      status == 429 ->
        {:rate_limited, parsed_message(body, "Rate limited (429)"), true}

      status in 500..599 ->
        {:server_error, parsed_message(body, "Provider error (#{status})"), true}

      true ->
        {:request_failed, parsed_message(body, "Request failed (#{status})"), false}
    end
  end

  defp parsed_message(body, fallback) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      _ -> fallback
    end
  end
end
