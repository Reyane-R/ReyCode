defmodule ReyCode.Provider.OpenAICompatible.HTTPC.RedirectTest do
  use ExUnit.Case, async: false

  alias ReyCode.Failure
  alias ReyCode.Provider.{Frame, OpenAICompatible, Request, Response, Runtime}
  alias ReyCode.Provider.OpenAICompatible.HTTP
  alias ReyCode.Provider.OpenAICompatible.HTTPC
  alias ReyCode.Provider.OpenAICompatible.Profile
  alias ReyCode.RuntimeConfig

  @loopback "127.0.0.1"

  setup do
    on_exit(fn -> System.delete_env("REAL_HTTP_API_KEY") end)

    :ok
  end

  defp real_http_runtime(port, request_timeout_ms) do
    %Runtime{
      module: OpenAICompatible,
      provider_id: :real_http,
      status: :configured,
      config:
        RuntimeConfig.fresh(
          openai_compatible_providers: [
            %{
              id: :real_http,
              name: "Real HTTP",
              base_url: "http://#{@loopback}:#{port}",
              key_env: "REAL_HTTP_API_KEY",
              request_timeout_ms: request_timeout_ms
            }
          ]
        ).open_ai
    }
  end

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
      wire_result(
        HTTPC.start(
          :post,
          "http://#{@loopback}:#{port}/api/v1/start",
          [{"Authorization", "Bearer hidden"}, {"Cookie", "sid=abc123"}],
          "",
          []
        )
      )

    assert {:ok, :ok, %{status: 200, headers: _headers}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))

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
      wire_result(
        HTTPC.start(
          :post,
          "http://#{@loopback}:#{start_port}/start",
          [{"Authorization", "Bearer hidden"}, {"Cookie", "sid=abc123"}, {"X-Trace", "keep"}],
          "",
          []
        )
      )

    assert {:ok, :ok, %{status: 200, headers: _headers}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))

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
      wire_result(HTTPC.start(:post, "http://#{@loopback}:#{port}/start", [], "", []))

    assert {:error, %{"category" => "request_failed"}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))
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
      wire_result(HTTPC.start(:post, "http://#{@loopback}:#{port}/start", [], "", []))

    assert {:error, %{"category" => "request_failed"}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))
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
      wire_result(
        HTTPC.start(
          :post,
          "http://#{@loopback}:#{port}/loop",
          [{"Authorization", "Bearer top-secret"}],
          "",
          max_redirects: 2
        )
      )

    assert {:error, %{"category" => "request_failed", "message" => message}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))

    assert message =~ "Too many redirects"
    refute message =~ "top-secret"
  end

  test "rejects an invalid transport context" do
    assert {:error, %{"category" => "request_failed", "message" => "Invalid transport context"}} =
             wire_result(HTTPC.collect(:not_a_context, fn _, _acc -> {:cont, :ok} end, :ok))
  end

  test "maps a server error status to a provider error" do
    start_test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn %{path: path, headers: headers} ->
        send(start_test_pid, {:request, path, headers})
        {500, [], ~s({"error":{"message":"upstream exploded"}})}
      end)

    on_exit(fn ->
      stop_test_server(listen_socket, server_pid)
    end)

    {:ok, context} =
      wire_result(HTTPC.start(:post, "http://#{@loopback}:#{port}/fail", [], "", []))

    assert {:error, %{"category" => "server_error", "retryable" => true, "message" => message}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))

    assert message =~ "upstream exploded"
  end

  test "maps a failed connection to a request failure" do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, free_port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, context} =
      wire_result(HTTPC.start(:post, "http://#{@loopback}:#{free_port}/nowhere", [], "", []))

    assert {:error, %{"category" => "request_failed", "retryable" => false}} =
             wire_result(HTTPC.collect(context, fn _, _acc -> {:cont, :ok} end, :ok))
  end

  test "halts chunk delivery when the consumer stops the stream" do
    start_test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn %{path: path, headers: headers} ->
        send(start_test_pid, {:request, path, headers})
        {200, [], "twelve bytes"}
      end)

    on_exit(fn ->
      stop_test_server(listen_socket, server_pid)
    end)

    {:ok, context} =
      wire_result(HTTPC.start(:post, "http://#{@loopback}:#{port}/chunks", [], "", []))

    on_event = fn
      {:partial, _chunk}, :ok ->
        {:halt, :ok, HTTP.error(:output_too_large, "consumer halted", false)}

      {:partial, _chunk}, acc ->
        {:cont, acc}
    end

    assert {:error, %{"category" => "output_too_large"}} =
             wire_result(HTTPC.collect(context, on_event, :ok))
  end

  test "sends GET without a body and preserves streamed response bytes" do
    test_pid = self()
    response = ~s({"data":[{"id":"café"}]})

    {listen_socket, server_pid, port} =
      start_test_server(fn request ->
        send(test_pid, {:request, request})
        {200, [{"Content-Type", "application/json"}], response}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)

    {:ok, context} =
      wire_result(HTTPC.start(:get, "http://#{@loopback}:#{port}/models", [], nil, []))

    assert {:ok, ^response, %{status: 200}} =
             wire_result(
               HTTPC.collect(context, fn {:partial, bytes}, acc -> {:cont, acc <> bytes} end, "")
             )

    assert_receive {:request, %{method: "GET", path: "/models", body: ""}}

    assert {:error, %{"category" => "launch_failed"}} =
             wire_result(HTTPC.start(:get, "http://#{@loopback}:#{port}/models", [], "", []))
  end

  test "delivers bytes before connection close" do
    test_pid = self()
    first = ~s(data: {"choices":[{"delta":{"content":"café"}}]}\n\n)
    first_wire = first <> ":" <> String.duplicate("padding", 2_000) <> "\n\n"
    last = "data: [DONE]\n\n"

    {listen_socket, server_pid, port} =
      start_test_server(fn _request ->
        {:raw,
         fn socket ->
           send_chunked_headers(socket)
           send_chunk(socket, first_wire)
           send(test_pid, {:server_waiting, self()})

           receive do
             :finish ->
               send_chunk(socket, last)
               :gen_tcp.send(socket, "0\r\n\r\n")
           end
         end}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)

    {:ok, context} =
      wire_result(
        HTTPC.start(:post, "http://#{@loopback}:#{port}/stream", [], "{}", timeout: 1_000)
      )

    task =
      Task.async(fn ->
        wire_result(
          HTTPC.collect(
            context,
            fn {:partial, bytes}, acc ->
              send(test_pid, {:streamed, bytes})
              {:cont, acc <> bytes}
            end,
            ""
          )
        )
      end)

    assert_receive {:server_waiting, connection_pid}, 500
    assert_receive {:streamed, streamed}, 500
    assert byte_size(streamed) > 0
    assert Task.yield(task, 0) == nil

    send(connection_pid, :finish)
    expected = first_wire <> last
    assert {:ok, ^expected, %{status: 200}} = Task.await(task, 1_000)
  end

  test "cancels a timed out stream and keeps request messages out of the caller mailbox" do
    test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn _request ->
        {:raw,
         fn socket ->
           send_chunked_headers(socket)
           send(test_pid, :response_started)
           send(test_pid, {:connection_result, :gen_tcp.recv(socket, 0, 5_000)})
         end}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)

    {:ok, context} =
      wire_result(
        HTTPC.start(:post, "http://#{@loopback}:#{port}/slow", [], "{}", timeout: 3_000)
      )

    assert {:error, %{"category" => "timeout", "retryable" => true}} =
             wire_result(HTTPC.collect(context, fn _, acc -> {:cont, acc} end, :ok))

    assert_receive :response_started, 5_000
    assert_receive {:connection_result, {:error, :closed}}, 5_000
    refute_receive {:http, _message}, 50
  end

  test "cancels a live stream when the callback halts" do
    test_pid = self()
    bytes = String.duplicate("stream-data", 2_000)

    {listen_socket, server_pid, port} =
      start_test_server(fn _request ->
        {:raw,
         fn socket ->
           send_chunked_headers(socket)
           send_chunk(socket, bytes)
           send(test_pid, {:halt_connection_result, :gen_tcp.recv(socket, 0, 1_000)})
         end}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)

    {:ok, context} =
      wire_result(
        HTTPC.start(:post, "http://#{@loopback}:#{port}/halt", [], "{}", timeout: 1_000)
      )

    on_event = fn {:partial, _chunk}, acc ->
      {:halt, acc, HTTP.error(:output_too_large, "consumer halted", false)}
    end

    assert {:error, %{"category" => "output_too_large"}} =
             wire_result(HTTPC.collect(context, on_event, :ok))

    assert_receive {:halt_connection_result, {:error, :closed}}, 1_000
    refute_receive {:http, _message}, 50
  end

  test "enables peer and hostname verification for TLS" do
    options = HTTPC.tls_options()

    assert options[:verify] == :verify_peer
    assert is_list(options[:cacerts])
    assert is_list(options[:customize_hostname_check])
    assert is_function(options[:customize_hostname_check][:match_fun], 2)
  end

  test "default provider transport streams a UTF-8 frame before connection close" do
    test_pid = self()
    first = ~s(data: {"choices":[{"delta":{"content":"café"}}]}\n\n)
    first_wire = first <> ":" <> String.duplicate("padding", 2_000) <> "\n\n"

    {listen_socket, server_pid, port} =
      start_test_server(fn request ->
        send(test_pid, {:provider_request, request})

        {:raw,
         fn socket ->
           send_chunked_headers(socket)
           send_chunk(socket, first_wire)
           send(test_pid, {:provider_waiting, self()})

           receive do
             :finish ->
               send_chunk(socket, "data: [DONE]\n\n")
               :gen_tcp.send(socket, "0\r\n\r\n")
           end
         end}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)

    System.put_env("REAL_HTTP_API_KEY", "secret")
    runtime = real_http_runtime(port, 15_000)

    task =
      Task.async(fn ->
        OpenAICompatible.stream(runtime, provider_request(), fn frame ->
          send(test_pid, {:provider_frame, frame})
          :ok
        end)
      end)

    assert_receive {:provider_request, %{method: "POST", path: "/chat/completions", body: body}},
                   5_000

    assert Jason.decode!(body)["stream"]
    assert_receive {:provider_waiting, connection_pid}
    assert_receive {:provider_frame, %Frame{kind: :text_delta, data: %{text: "café"}}}, 5_000
    assert Task.yield(task, 0) == nil

    send(connection_pid, :finish)
    assert {:ok, %Response{text: "café"}} = Task.await(task, 15_000)
  end

  test "provider timeout releases a relay callback and cancels the HTTP request" do
    test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn _request ->
        {:raw,
         fn socket ->
           send_chunked_headers(socket)
           send_chunk(socket, ~s(data: {"choices":[{"delta":{"content":"blocked"}}]}\n\n))
           send(test_pid, {:timeout_connection_result, :gen_tcp.recv(socket, 0, 5_000)})
         end}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)

    System.put_env("REAL_HTTP_API_KEY", "secret")
    runtime = real_http_runtime(port, 3_000)

    assert {:error, %{"category" => "timeout"}} =
             wire_result(
               OpenAICompatible.stream(runtime, provider_request(), fn _frame ->
                 Process.sleep(5_000)
                 :ok
               end)
             )

    assert_receive {:timeout_connection_result, {:error, :closed}}, 5_000
  end

  test "real model discovery is bounded and strict across response classes" do
    System.put_env("REAL_HTTP_API_KEY", "secret")

    cases = [
      {200, ~s({"data":[{"id":"z"},{"id":"a"},{"id":"a"}]}), [],
       %{status: :configured, models: ["a", "z"]}},
      {200, ~s({"data":[]}), [], %{status: :configured, models: []}},
      {200, ~s({"data":[42]}), [], %{status: :error, models: []}},
      {200, "not-json", [], %{status: :error, models: []}},
      {200, ~s({"data":[{"id":"too-large"}]}), [max_response_bytes: 8],
       %{status: :error, models: []}},
      {429, ~s({"error":{"message":"slow down"}}), [], %{status: :error, models: []}}
    ]

    for {status, body, opts, expected} <- cases do
      {listen_socket, server_pid, port} =
        start_test_server(fn _request ->
          {status, [{"Content-Type", "application/json"}], body}
        end)

      profile = %Profile{
        id: :real_models,
        name: "Real Models",
        base_url: "http://#{@loopback}:#{port}",
        key_env: "REAL_HTTP_API_KEY",
        request_timeout_ms: 1_000
      }

      result = OpenAICompatible.discover(profile, opts)
      stop_test_server(listen_socket, server_pid)

      assert {:ok, actual} = result
      assert Map.take(actual, [:status, :models]) == expected
    end
  end

  test "real model discovery uses GET with no body" do
    test_pid = self()

    {listen_socket, server_pid, port} =
      start_test_server(fn request ->
        send(test_pid, {:model_request, request})
        {200, [{"Content-Type", "application/json"}], ~s({"data":[]})}
      end)

    on_exit(fn -> stop_test_server(listen_socket, server_pid) end)
    System.put_env("REAL_HTTP_API_KEY", "secret")

    profile = %Profile{
      id: :real_models,
      name: "Real Models",
      base_url: "http://#{@loopback}:#{port}",
      key_env: "REAL_HTTP_API_KEY",
      request_timeout_ms: 1_000
    }

    assert {:ok, %{status: :configured, models: []}} = OpenAICompatible.discover(profile)
    assert_receive {:model_request, %{method: "GET", path: "/models", body: ""}}
  end

  defp request_has_header?(headers, name) do
    headers
    |> Enum.any?(fn {header_name, _value} ->
      String.downcase(header_name) == String.downcase(name)
    end)
  end

  defp provider_request do
    %Request{
      invocation_id: "inv-real",
      turn_id: "turn-real",
      room_id: "room-real",
      mode: :compare,
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "testing",
        provider: :real_http,
        model: "model"
      },
      system_prompt: "Test.",
      messages: [%{role: :user, content: "Hi", author: %{id: "user", name: "You"}}],
      workspace: System.tmp_dir!(),
      resume_from: 0,
      round_index: 0
    }
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
      body = read_body!(socket, headers)
      request = %{method: method, path: path, headers: headers, body: body}

      case handler.(request) do
        {:raw, response} ->
          response.(socket)

        {status, response_headers, response_body} ->
          send_response(socket, status, response_headers, response_body)
      end
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, method, path} <- read_request_line(socket),
         {:ok, headers} <- read_headers(socket, []) do
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

  defp read_body!(socket, headers) do
    case request_body_length(headers) do
      0 ->
        ""

      length when is_integer(length) and length > 0 ->
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, length, 5_000)
        body

      _ ->
        ""
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

  defp send_chunked_headers(socket) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
        "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    )
  end

  defp send_chunk(socket, bytes) do
    :gen_tcp.send(socket, [Integer.to_string(byte_size(bytes), 16), "\r\n", bytes, "\r\n"])
  end

  defp status_reason(200), do: "OK"
  defp status_reason(302), do: "Found"
  defp status_reason(_), do: "OK"
  defp wire_result({:error, %Failure{} = failure}), do: {:error, Failure.to_wire(failure)}
  defp wire_result(result), do: result
end
