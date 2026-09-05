defmodule ReyCode.Provider.OpenAICompatible.HTTPC do
  @moduledoc false

  alias ReyCode.Failure
  alias ReyCode.Provider.OpenAICompatible.HTTP

  @behaviour HTTP

  @default_timeout 60_000
  @default_max_redirects 5

  @type request_context :: %{
          :method => HTTP.method(),
          :url => String.t(),
          :headers => [{String.t(), String.t()}],
          :body => String.t() | nil,
          :deadline => integer(),
          :max_redirects => non_neg_integer(),
          :ssl => keyword()
        }

  @impl true
  def start(method, url, headers, body, opts)
      when method in [:get, :post] and (is_binary(body) or is_nil(body)) do
    with :ok <- start_inets(),
         :ok <- start_ssl(),
         :ok <- valid_body?(method, body) do
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      {:ok,
       %{
         method: method,
         url: to_string(url),
         headers: normalize_headers(headers),
         body: body,
         deadline: monotonic_ms() + timeout,
         max_redirects: Keyword.get(opts, :max_redirects, @default_max_redirects),
         ssl: Keyword.get(opts, :ssl, tls_options())
       }}
    else
      {:error, reason} -> {:error, HTTP.error(:launch_failed, inspect(reason), false)}
    end
  end

  def start(_method, _url, _headers, _body, _opts) do
    {:error, HTTP.error(:launch_failed, "Invalid HTTP request", false)}
  end

  @impl true
  def collect(%{} = context, on_event, acc) do
    owner = self()
    result_tag = make_ref()

    {collector, monitor} =
      spawn_monitor(fn ->
        request = %{
          context: context,
          on_event: on_event,
          acc: acc,
          url: context.url,
          headers: context.headers,
          body: context.body,
          redirects: 0,
          owner_monitor: Process.monitor(owner)
        }

        case collect(request) do
          :owner_down -> :ok
          result -> send(owner, {result_tag, result})
        end
      end)

    # The collector enforces the request deadline and this monitor guarantees
    # termination if it exits before replying.
    receive do
      {^result_tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^collector, reason} ->
        {:error,
         HTTP.error(:request_failed, "Transport collector exited: #{inspect(reason)}", false)}
    end
  end

  def collect(_invalid, _on_event, _acc) do
    {:error, HTTP.error(:request_failed, "Invalid transport context", false)}
  end

  # One request map threads every hop of the redirect chain: the fixed
  # transport context, the callback and accumulator, and the per-hop URL,
  # headers, body, redirect count, and owner monitor.
  defp collect(%{redirects: redirects} = request) when redirects >= 0 do
    with {:ok, timeout} <- remaining_timeout(request.context.deadline),
         {:ok, request_id} <-
           request(
             request.context.method,
             request.url,
             request.headers,
             request.body,
             timeout,
             request.context.ssl
           ) do
      await_response(request_id, request)
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, request_error(reason)}
    end
  end

  defp request(method, url, headers, body, timeout, ssl) do
    request = request_tuple(method, url, headers, body)
    http_opts = [timeout: timeout, connect_timeout: timeout, autoredirect: false, ssl: ssl]
    request_opts = [sync: false, stream: :self, body_format: :binary]

    :httpc.request(method, request, http_opts, request_opts)
  end

  defp request_tuple(:get, url, headers, nil), do: {to_charlist(url), headers}

  defp request_tuple(:post, url, headers, body),
    do: {to_charlist(url), headers, ~c"application/json", body}

  defp await_response(request_id, request) do
    case remaining_timeout(request.context.deadline) do
      {:ok, timeout} -> receive_response(request_id, request, timeout)
      {:error, error} -> cancel_and_error(request_id, error)
    end
  end

  defp receive_response(request_id, request, timeout) do
    receive do
      {:http, {^request_id, :stream_start, response_headers}} ->
        await_stream(request_id, request, response_headers)

      {:http, {^request_id, {{_version, status, _reason}, response_headers, body}}} ->
        handle_complete_response(status, response_headers, body, request)

      {:http, {^request_id, {:error, reason}}} ->
        {:error, request_error(reason)}

      {:DOWN, owner_monitor, :process, _owner, _reason}
      when owner_monitor == request.owner_monitor ->
        cancel_and_drain(request_id)
        :owner_down
    after
      timeout ->
        cancel_and_error(request_id, timeout_error())
    end
  end

  defp await_stream(request_id, request, response_headers) do
    case remaining_timeout(request.context.deadline) do
      {:ok, timeout} ->
        receive do
          {:http, {^request_id, :stream, data}} when is_binary(data) ->
            case call_before(
                   request.on_event,
                   {:partial, data},
                   request.acc,
                   request.context.deadline
                 ) do
              {:ok, {:cont, next}} ->
                await_stream(request_id, %{request | acc: next}, response_headers)

              {:ok, {:halt, _next, error}} ->
                cancel_and_error(request_id, error)

              {:error, error} ->
                cancel_and_error(request_id, error)
            end

          {:http, {^request_id, :stream_end, end_headers}} ->
            headers = normalize_response_headers(end_headers || response_headers)
            {:ok, request.acc, %{status: 200, headers: headers}}

          {:http, {^request_id, {:error, reason}}} ->
            {:error, request_error(reason)}

          {:DOWN, owner_monitor, :process, _owner, _reason}
          when owner_monitor == request.owner_monitor ->
            cancel_and_drain(request_id)
            :owner_down
        after
          timeout ->
            cancel_and_error(request_id, timeout_error())
        end

      {:error, error} ->
        cancel_and_error(request_id, error)
    end
  end

  defp handle_complete_response(status, response_headers, body, request)
       when status in 200..299 do
    case call_before(
           request.on_event,
           {:partial, IO.iodata_to_binary(body)},
           request.acc,
           request.context.deadline
         ) do
      {:ok, {:cont, next}} ->
        {:ok, next, %{status: status, headers: normalize_response_headers(response_headers)}}

      {:ok, {:halt, _next, error}} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp handle_complete_response(status, response_headers, _body, request)
       when status in 300..399 do
    maybe_follow_redirect(status, response_headers, request)
  end

  defp handle_complete_response(status, _headers, body, _request) do
    {:error, HTTP.status_error(status, IO.iodata_to_binary(body))}
  end

  defp maybe_follow_redirect(status, response_headers, request) do
    location = redirect_location(response_headers, request.url)

    cond do
      location == nil ->
        {:error, HTTP.status_error(status, "")}

      request.redirects >= request.context.max_redirects ->
        {:error,
         HTTP.error(:request_failed, "Too many redirects while requesting #{request.url}", false)}

      https_downgrade?(request.url, location) ->
        {:error,
         HTTP.error(
           :request_failed,
           "Refusing insecure HTTPS-to-HTTP redirect to #{location}",
           false
         )}

      true ->
        next_headers = sanitize_headers_for_redirect(request.headers, request.url, location)

        collect(%{
          request
          | url: location,
            headers: next_headers,
            redirects: request.redirects + 1
        })
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

  defp normalize_response_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp valid_body?(:get, nil), do: :ok
  defp valid_body?(:post, body) when is_binary(body), do: :ok
  defp valid_body?(_method, _body), do: {:error, :invalid_request_body}

  defp remaining_timeout(deadline) do
    case deadline - monotonic_ms() do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, timeout_error()}
    end
  end

  defp timeout_error,
    do: HTTP.error(:timeout, "HTTP request exceeded its deadline", true)

  defp request_error(:timeout), do: timeout_error()

  defp request_error({:failed_connect, details}) when is_list(details) do
    reason =
      details
      |> Enum.take(8)
      |> Enum.find_value(:failed_connect, fn
        {_family, _options, reason}
        when reason in [:econnrefused, :nxdomain, :enetunreach, :ehostunreach, :timeout] ->
          reason

        _detail ->
          nil
      end)

    Failure.new(:request_failed, "HTTP connection failed: #{reason}", false, reason)
  end

  defp request_error(reason), do: HTTP.error(:request_failed, inspect(reason), false)

  defp cancel_and_error(request_id, error) do
    cancel_and_drain(request_id)
    {:error, error}
  end

  defp cancel_and_drain(request_id) do
    _ = :httpc.cancel_request(request_id)
    drain_request_messages(request_id)
  end

  defp call_before(on_event, event, acc, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline) do
      task =
        Task.async(fn ->
          try do
            {:ok, on_event.(event, acc)}
          rescue
            exception ->
              {:error,
               HTTP.error(
                 :request_failed,
                 "Transport callback crashed: #{Exception.message(exception)}",
                 false
               )}
          catch
            kind, reason ->
              {:error,
               HTTP.error(
                 :request_failed,
                 "Transport callback crashed: #{Exception.format_banner(kind, reason)}",
                 false
               )}
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error,
           HTTP.error(:request_failed, "Transport callback exited: #{inspect(reason)}", false)}

        nil ->
          {:error, timeout_error()}
      end
    end
  end

  defp drain_request_messages(request_id) do
    receive do
      {:http, {^request_id, _message}} -> drain_request_messages(request_id)
      {:http, {^request_id, _kind, _message}} -> drain_request_messages(request_id)
    after
      0 -> :ok
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

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

  @doc false
  @spec tls_options() :: keyword()
  def tls_options, do: [depth: 3] ++ :httpc.ssl_verify_host_options(true)
end
