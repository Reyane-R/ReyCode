defmodule ReyCode.Provider.OpenAICompatible.HTTPC do
  @moduledoc false

  @behaviour ReyCode.Provider.OpenAICompatible.HTTP

  alias ReyCode.Provider.OpenAICompatible.HTTP

  @impl true
  def start(url, headers, body, opts) do
    ensure_started()

    request = {
      String.to_charlist(url),
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end),
      ~c"application/json",
      body
    }

    http_opts = [
      ssl: ssl_opts(),
      timeout: Keyword.get(opts, :timeout, 600_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 30_000),
      autoredirect: true
    ]

    case :httpc.request(:post, request, http_opts, sync: false, stream: :self, receiver: self()) do
      {:ok, request_id} ->
        {:ok, request_id}

      {:error, reason} ->
        {:error, HTTP.error("request_failed", "HTTP request failed: #{inspect(reason)}", true)}
    end
  end

  @impl true
  def collect(request_id, on_event, acc) do
    receive do
      {:http, {^request_id, {:partial, data}}} ->
        case on_event.({:partial, IO.iodata_to_binary(data)}, acc) do
          {:cont, acc} -> collect(request_id, on_event, acc)
          {:halt, _acc, error} -> {:error, error}
        end

      {:http, {^request_id, {{_version, status, _reason}, _headers, body}}}
      when status in 200..299 ->
        {:ok, acc, %{status: status, body: IO.iodata_to_binary(body)}}

      {:http, {^request_id, {{_version, status, _reason}, _headers, body}}} ->
        {:error, HTTP.status_error(status, IO.iodata_to_binary(body))}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, HTTP.error("request_failed", "HTTP error: #{inspect(reason)}", true)}
    end
  end

  defp ensure_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp ssl_opts do
    [verify: :verify_peer, depth: 3, cacerts: cacerts()]
  end

  defp cacerts do
    _ = :public_key.cacerts_load()
    :public_key.cacerts_get()
  end
end
