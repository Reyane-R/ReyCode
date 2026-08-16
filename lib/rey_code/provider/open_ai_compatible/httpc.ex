defmodule ReyCode.Provider.OpenAICompatible.HTTPC do
  @moduledoc false

  alias ReyCode.Provider.OpenAICompatible.HTTP

  @behaviour HTTP

  @default_timeout 60_000
  @default_max_redirects 5
  @default_chunk_bytes 8_192

  @type request_context :: %{
          :url => String.t(),
          :headers => [{String.t(), String.t()}],
          :body => String.t(),
          :timeout => non_neg_integer(),
          :max_redirects => non_neg_integer(),
          :chunk_bytes => pos_integer()
        }

  @impl true
  def start(url, headers, body, opts) do
    with :ok <- start_inets(),
         :ok <- start_ssl() do
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      {:ok,
       %{
         url: to_string(url),
         headers: normalize_headers(headers),
         body: to_string(body),
         timeout: timeout,
         max_redirects: Keyword.get(opts, :max_redirects, @default_max_redirects),
         chunk_bytes: Keyword.get(opts, :chunk_bytes, @default_chunk_bytes)
       }}
    else
      {:error, reason} -> {:error, HTTP.error("launch_failed", inspect(reason), false)}
    end
  end

  @impl true
  def collect(%{} = context, on_event, acc) do
    collect(context, context.url, context.headers, context.body, on_event, acc, 0)
  end

  def collect(_invalid, _on_event, _acc) do
    {:error, HTTP.error("request_failed", "Invalid transport context", false)}
  end

  defp collect(context, url, headers, body, on_event, acc, redirects) when redirects >= 0 do
    request = {to_charlist(url), headers, ~c"application/json", body}
    http_opts = [timeout: context.timeout, autoredirect: false, ssl: ssl_opts()]

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        response_body_binary = to_string(response_body)

        case status do
          status when status in 200..299 ->
            emit_chunks(response_body_binary, context.chunk_bytes, on_event, acc)
            |> finalize_collect(status, response_body_binary)

          status when status in 300..399 ->
            maybe_follow_redirect(
              status,
              response_headers,
              %{
                url: url,
                headers: headers,
                body: body,
                context: context,
                on_event: on_event,
                acc: acc,
                redirects: redirects
              }
            )

          status ->
            {:error, HTTP.status_error(status, response_body_binary)}
        end

      {:error, reason} ->
        {:error, HTTP.error("request_failed", inspect(reason), false)}
    end
  end

  defp emit_chunks(body, chunk_bytes, on_event, acc) do
    chunks = split_chunks(to_string(body), chunk_bytes)

    Enum.reduce_while(chunks, {:cont, acc}, fn chunk, {:cont, current} ->
      case on_event.({:partial, chunk}, current) do
        {:cont, next} -> {:cont, {:cont, next}}
        {:halt, next, error} -> {:halt, {:error, error, next}}
      end
    end)
    |> case do
      {:cont, final} -> {:ok, final}
      {:error, error, _next} -> {:error, error}
    end
  end

  defp finalize_collect(result, status, body) do
    case result do
      {:ok, final} -> {:ok, final, %{status: status, body: body}}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_follow_redirect(status, response_headers, request) do
    location = redirect_location(response_headers, request.url)

    cond do
      location == nil ->
        {:error, HTTP.status_error(status, "")}

      request.redirects >= request.context.max_redirects ->
        {:error,
         HTTP.error("request_failed", "Too many redirects while requesting #{request.url}", false)}

      https_downgrade?(request.url, location) ->
        {:error,
         HTTP.error(
           "request_failed",
           "Refusing insecure HTTPS-to-HTTP redirect to #{location}",
           false
         )}

      true ->
        next_headers = sanitize_headers_for_redirect(request.headers, request.url, location)

        collect(
          request.context,
          location,
          next_headers,
          request.body,
          request.on_event,
          request.acc,
          request.redirects + 1
        )
    end
  end

  defp redirect_location(response_headers, current_url) do
    case Enum.find_value(response_headers, &location_header/1) do
      nil ->
        nil

      location_value ->
        resolve_redirect_location(location_value, current_url)
    end
  end

  defp location_header({name, value}) when is_list(name) do
    case String.downcase(to_string(name)) do
      "location" -> String.trim(to_string(value))
      _ -> nil
    end
  end

  defp resolve_redirect_location(raw, current_url) do
    resolved =
      case String.trim(raw) do
        "" ->
          nil

        value ->
          case URI.parse(value) do
            %URI{host: nil, scheme: nil} ->
              URI.to_string(URI.merge(URI.parse(current_url), value))

            uri ->
              URI.to_string(uri)
          end
      end

    resolved
  end

  defp sanitize_headers_for_redirect(headers, from_url, to_url) do
    if same_origin?(from_url, to_url) do
      headers
    else
      Enum.reject(headers, &authorization_header?/1)
    end
  end

  defp same_origin?(from_url, to_url) do
    parse = &URI.parse/1

    from = parse.(from_url)
    to = parse.(to_url)

    from.scheme == to.scheme and from.host == to.host and from.port == to.port
  end

  @doc false
  @spec https_downgrade?(String.t(), String.t()) :: boolean()
  def https_downgrade?(from_url, to_url) do
    %{scheme: from_scheme} = URI.parse(from_url)
    %{scheme: to_scheme} = URI.parse(to_url)

    from_scheme == "https" and to_scheme == "http"
  end

  defp authorization_header?({name, _value}) when is_list(name) do
    String.downcase(to_string(name)) in ["authorization", "cookie"]
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp split_chunks(data, chunk_size) do
    chunk_size = max(1, chunk_size)
    split_chunks(to_string(data), chunk_size, [])
  end

  defp split_chunks("", _chunk_size, _chunks), do: []

  defp split_chunks(data, chunk_size, chunks) when byte_size(data) <= chunk_size do
    Enum.reverse([data | chunks])
  end

  defp split_chunks(data, chunk_size, chunks) do
    <<chunk::binary-size(chunk_size), rest::binary>> = data
    split_chunks(rest, chunk_size, [chunk | chunks])
  end

  defp start_inets do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_ssl do
    case :ssl.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssl_opts do
    [verify: :verify_peer, depth: 3, cacerts: cacerts()]
  end

  defp cacerts do
    _ = :public_key.cacerts_load()
    :public_key.cacerts_get()
  end
end
