defmodule ReyCode.WebTest do
  use ExUnit.Case, async: false

  alias ReyCode.CLI.Desktop
  alias ReyCode.Web

  test "desktop accepts only an optional valid port" do
    assert Desktop.parse([]) == {:ok, Web.default_port()}
    assert Desktop.parse(["--port", "5000"]) == {:ok, 5000}
    assert Desktop.parse(["--port", "0"]) == {:error, :usage}
    assert Desktop.parse(["--port", "70000"]) == {:error, :usage}
    assert Desktop.parse(["extra"]) == {:error, :usage}
    assert Desktop.parse(["--nope"]) == {:error, :usage}
  end

  test "start is idempotent and every page needs the access token" do
    on_exit(fn ->
      _ = Supervisor.terminate_child(ReyCode.Supervisor, ReyCode.Web.Endpoint)
      _ = Supervisor.delete_child(ReyCode.Supervisor, ReyCode.Web.Endpoint)
    end)

    port = free_port()
    assert {:ok, pid} = Web.start(port)
    assert {:ok, ^pid} = Web.start(port)
    assert {403, _headers} = get(port, "/")
    assert {302, headers} = get(port, "/sessions/x?token=" <> Web.token())
    assert headers =~ ~r/location: \/sessions\/x\r\n/i
    assert headers =~ ~r/set-cookie: _rey_code_web=/i
    assert {403, _headers} = get(port, "/?token=wrong")
  end

  test "a taken port names itself in the error" do
    assert Web.describe_error({:shutdown, {:listen, :eaddrinuse}}, 4747) =~
             "Port 4747 is already in use"

    assert Web.describe_error(:boom, 4747) =~ "Could not start ReyCode Desktop: :boom"
  end

  defp get(port, path) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      )

    {:ok, response} = recv_all(socket, "")
    [head | _body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1 " <> <<status::binary-size(3)>> <> _reason | _lines] = String.split(head, "\r\n")
    {String.to_integer(status), head <> "\r\n"}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
