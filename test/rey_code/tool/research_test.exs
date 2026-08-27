defmodule ReyCode.Tool.ResearchTest do
  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{DocumentRead, Request, Result, WebSearch}

  test "normalizes configured search JSON and rich HTML documents" do
    {:ok, search_listener} = listen()
    {:ok, {_address, search_port}} = :inet.sockname(search_listener)

    search_task =
      Task.async(fn ->
        serve(
          search_listener,
          Jason.encode!(%{
            "web" => %{
              "results" => [
                %{
                  "title" => "ReyCode",
                  "url" => "https://example.test",
                  "description" => "A durable harness"
                }
              ]
            }
          }),
          "application/json"
        )
      end)

    search_policy =
      RuntimeConfig.fresh(
        web_search_endpoint: "http://127.0.0.1:#{search_port}/search",
        web_search_max_results: 3
      ).tools.research

    assert {:ok, %{"results" => [%{"title" => "ReyCode"}]}} =
             WebSearch.search("durable", search_policy)

    assert Task.await(search_task, 1_000) =~ "q=durable"
    :gen_tcp.close(search_listener)

    {:ok, document_listener} = listen()
    {:ok, {_address, document_port}} = :inet.sockname(document_listener)

    document_task =
      Task.async(fn ->
        serve(
          document_listener,
          "<html><body><h1>Hello</h1><p>World</p></body></html>",
          "text/html"
        )
      end)

    document_policy = RuntimeConfig.fresh(document_read_timeout_ms: 1_000).tools.research

    request =
      Request.new(
        tool: "read_url",
        arguments: %{url: "http://127.0.0.1:#{document_port}/doc"},
        workspace: System.tmp_dir!(),
        roots: [System.tmp_dir!()]
      )

    assert %Result{ok: true, output: text, metadata: %{"content_type" => "text/html"}} =
             DocumentRead.run(request, policy: document_policy)

    assert text =~ "Hello"
    assert text =~ "World"
    assert Task.await(document_task, 1_000) =~ "GET /doc"
    :gen_tcp.close(document_listener)
  end

  defp listen, do: :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])

  defp serve(listener, body, content_type) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.send(socket, response(body, content_type))
    :gen_tcp.close(socket)
    request
  end

  defp response(body, content_type) do
    [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: ",
      content_type,
      "\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]
  end
end
