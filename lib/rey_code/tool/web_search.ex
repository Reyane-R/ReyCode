defmodule ReyCode.Tool.WebSearch do
  @moduledoc "Bounded web search through a configured JSON search endpoint."

  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig.Tools.Research
  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments}, opts) do
    %Research{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, query} <- Support.require_arg(arguments, :query),
         :ok <- valid_query(query),
         {:ok, response} <- search(query, policy) do
      Result.ok(Jason.encode!(response))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Queries the configured provider and normalizes bounded search results."
  @spec search(String.t(), Research.t()) :: {:ok, map()} | {:error, term()}
  def search(query, policy) do
    with endpoint when is_binary(endpoint) <- policy.search_endpoint,
         {:ok, uri} <- search_uri(endpoint, query),
         {:ok, headers} <- headers(policy),
         {:ok, body} <- get(uri, headers, policy.search_timeout_ms, policy.max_bytes),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, normalize(decoded, policy.max_results)}
    else
      nil -> {:error, :web_search_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_query(query),
    do: if(String.trim(query) == "", do: {:error, :empty_search_query}, else: :ok)

  defp search_uri(endpoint, query) do
    uri =
      endpoint <>
        if(String.contains?(endpoint, "?"), do: "&", else: "?") <>
        URI.encode_query(%{"q" => query})

    case URI.parse(uri) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> {:ok, uri}
      _ -> {:error, :invalid_web_search_endpoint}
    end
  end

  defp headers(%Research{search_key_env: nil}), do: {:ok, []}

  defp headers(%Research{search_key_env: env}) do
    case System.get_env(env) do
      key when is_binary(key) and key != "" ->
        {:ok, [{~c"x-subscription-token", String.to_charlist(key)}]}

      _ ->
        {:error, :web_search_credentials_missing}
    end
  end

  defp get(uri, headers, timeout_ms, max_bytes) do
    request = {String.to_charlist(uri), headers}
    options = [{:timeout, timeout_ms}, {:connect_timeout, timeout_ms}]

    case :httpc.request(:get, request, options, []) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        body = IO.iodata_to_binary(body)
        if byte_size(body) <= max_bytes, do: {:ok, body}, else: {:error, :web_response_too_large}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:web_status, status}}

      {:error, reason} ->
        {:error, {:web_request_failed, reason}}
    end
  end

  defp normalize(decoded, max_results) do
    results = Map.get(decoded, "web", %{}) |> Map.get("results", Map.get(decoded, "results", []))

    normalized =
      results
      |> List.wrap()
      |> Enum.take(max_results)
      |> Enum.map(fn result ->
        %{
          "title" => Map.get(result, "title", ""),
          "url" => Map.get(result, "url", Map.get(result, "link", "")),
          "description" => Map.get(result, "description", Map.get(result, "snippet", ""))
        }
      end)

    %{
      "query" => decoded |> Map.get("query", %{}) |> Map.get("original", nil) || "",
      "results" => normalized
    }
  end
end
