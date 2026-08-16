defmodule ReyCode.Provider.OpenAICompatible.HTTPC.RedirectTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.OpenAICompatible.HTTPC

  @loopback "127.0.0.1"

  test "parses charlist Location headers, resolves relative redirects, and preserves credentials on same-origin redirects" do
    start_test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn %{path: path, headers: headers} ->
        send(start_test_pid, {:request, path, headers})

        case path do
          "/api/v1/start" ->
            {302, [{"Location", "  next  "}], ""}

          "/api/v1/next" ->
            {200, [{"Content-Type", "application/json"}], ~s({"ok":true})}

          _ ->
            {404, [], ""}
        end
      end)

    on_exit(fn ->
      stop_test_server(listen_socket, server_pid)
    end)

    {:ok, context} =
      HTTPC.start(
        "http://#{@loopback}:#{port}/api/v1/start",
        [{"Authorization", "Bearer hidden"}, {"Cookie", "sid=abc123"}],
        "",
        []
      )

    assert {:ok, :ok, %{status: 200, body: ~s({"ok":true})}} ==
             HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok)

    assert_receive {:request, "/api/v1/start", start_headers}, 1_000
    assert_receive {:request, "/api/v1/next", next_headers}, 1_000

    assert request_has_header?(start_headers, "authorization")
    assert request_has_header?(start_headers, "cookie")
    assert request_has_header?(next_headers, "authorization")
    assert request_has_header?(next_headers, "cookie")
  end

  test "strips authorization and cookie headers when redirecting across origins" do
    start_test_pid = self()

    {target_listen, target_server, target_port} =
      start_test_server(fn %{path: path, headers: headers} ->
        send(start_test_pid, {:request, path, headers})
        {200, [{"Content-Type", "text/plain"}], "ok"}
      end)

    {start_listen, start_server, start_port} =
      start_test_server(fn %{path: path, headers: headers} ->
        send(start_test_pid, {:request, path, headers})

        location = "http://#{@loopback}:#{target_port}/final"
        {302, [{"Location", location}], ""}
      end)

    on_exit(fn ->
      stop_test_server(start_listen, start_server)
      stop_test_server(target_listen, target_server)
    end)

    {:ok, context} =
      HTTPC.start(
        "http://#{@loopback}:#{start_port}/start",
        [{"Authorization", "Bearer hidden"}, {"Cookie", "sid=abc123"}, {"X-Trace", "keep"}],
        "",
        []
      )

    assert {:ok, :ok, %{status: 200, body: "ok"}} ==
             HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok)

    assert_receive {:request, "/start", start_headers}, 1_000
    assert_receive {:request, "/final", final_headers}, 1_000

    assert request_has_header?(start_headers, "authorization")
    assert request_has_header?(start_headers, "cookie")
    assert request_has_header?(start_headers, "x-trace")
    refute request_has_header?(final_headers, "authorization")
    refute request_has_header?(final_headers, "cookie")
  end

  test "returns request_failed when Location header is missing" do
    start_test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn request ->
        send(start_test_pid, {:request, request.path, request.headers})
        {302, [], ""}
      end)

    on_exit(fn ->
      stop_test_server(listen_socket, server_pid)
    end)

    {:ok, context} =
      HTTPC.start("http://#{@loopback}:#{port}/start", [], "", [])

    assert {:error, %{"category" => "request_failed"}} =
             HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok)
  end

  test "returns request_failed when Location header is invalid" do
    start_test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn request ->
        send(start_test_pid, {:request, request.path, request.headers})
        {302, [{"Location", "   "}], ""}
      end)

    on_exit(fn ->
      stop_test_server(listen_socket, server_pid)
    end)

    {:ok, context} =
      HTTPC.start("http://#{@loopback}:#{port}/start", [], "", [])

    assert {:error, %{"category" => "request_failed"}} =
             HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok)
  end

  test "rejects HTTPS-to-HTTP redirects before following" do
    assert HTTPC.https_downgrade?("https://api.example.com/v1", "http://api.example.com/v1")
    assert HTTPC.https_downgrade?("https://api.example.com", "http://evil.example.com")

    refute HTTPC.https_downgrade?("https://api.example.com", "https://api.example.com")
    refute HTTPC.https_downgrade?("http://api.example.com", "https://api.example.com")
    refute HTTPC.https_downgrade?("http://a.example.com", "http://b.example.com")
  end

  test "bounds redirect hops and keeps credentials out of the error text" do
    start_test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn %{path: path, headers: headers} ->
        send(start_test_pid, {:request, path, headers})
        {302, [{"Location", "/loop"}], ""}
      end)

    on_exit(fn ->
      stop_test_server(listen_socket, server_pid)
    end)

    {:ok, context} =
      HTTPC.start(
        "http://#{@loopback}:#{port}/loop",
        [{"Authorization", "Bearer top-secret"}],
        "",
        max_redirects: 2
      )

    assert {:error, %{"category" => "request_failed", "message" => message}} =
             HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok)

    assert message =~ "Too many redirects"
    refute message =~ "top-secret"
  end

  defp request_has_header?(headers, name) do
    headers
    |> Enum.any?(fn {header_name, _value} ->
      String.downcase(header_name) == String.downcase(name)
    end)
  end

  defp start_test_server(handler) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:packet, :line}])

    {:ok, port} = :inet.port(listen_socket)

    server_pid =
      spawn(fn ->
        accept_loop(listen_socket, handler)
      end)

    {listen_socket, server_pid, port}
  end

  defp stop_test_server(listen_socket, server_pid) do
    :gen_tcp.close(listen_socket)

    if Process.alive?(server_pid) do
      Process.exit(server_pid, :shutdown)
    end
  end

  defp accept_loop(listen_socket, handler) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Task.start(fn -> handle_connection(socket, handler) end)
        accept_loop(listen_socket, handler)

      {:error, :closed} ->
        :ok

      _ ->
        accept_loop(listen_socket, handler)
    end
  end

  defp handle_connection(socket, handler) do
    with {:ok, method, path, headers} <- read_request(socket) do
      request = %{method: method, path: path, headers: headers}
      {status, response_headers, body} = handler.(request)
      send_response(socket, status, response_headers, body)
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, method, path} <- read_request_line(socket),
         {:ok, headers} <- read_headers(socket, []),
         :ok <- read_body(socket, headers) do
      {:ok, method, path, headers}
    end
  end

  defp read_request_line(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} ->
        case String.split(String.trim(line, "\r\n"), " ", parts: 3) do
          [method, path, _proto] ->
            {:ok, method, path}

          _ ->
            {:error, :bad_request}
        end

      _ ->
        {:error, :bad_request}
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} -> read_header_line(String.trim(line, "\r\n"), socket, acc)
      _ -> {:error, :bad_request}
    end
  end

  defp read_header_line("", _socket, acc), do: {:ok, Enum.reverse(acc)}

  defp read_header_line(line, socket, acc) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        read_headers(socket, [{String.downcase(String.trim(name)), String.trim(value)} | acc])

      _ ->
        {:error, :bad_request}
    end
  end

  defp read_body(socket, headers) do
    case request_body_length(headers) do
      0 ->
        :ok

      length when is_integer(length) and length > 0 ->
        case :gen_tcp.recv(socket, length, 5_000) do
          {:ok, _} -> :ok
          _ -> {:error, :bad_request}
        end

      _ ->
        :ok
    end
  end

  defp request_body_length(headers) do
    Enum.find_value(headers, fn
      {"content-length", value} ->
        String.to_integer(value)

      _ ->
        nil
    end)
  end

  defp send_response(socket, status, headers, body) do
    body = to_string(body)
    content_length = byte_size(body)

    response_headers =
      [{"Content-Length", Integer.to_string(content_length)}, {"Connection", "close"}] ++ headers

    response =
      [
        "HTTP/1.1 #{status} #{status_reason(status)}\r\n",
        Enum.map(response_headers, fn {name, value} ->
          "#{name}: #{value}\r\n"
        end),
        "\r\n",
        body
      ]

    :gen_tcp.send(socket, response)
  end

  defp status_reason(200), do: "OK"
  defp status_reason(302), do: "Found"
  defp status_reason(_), do: "OK"
end
