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

  test "start is idempotent and serves loopback only" do
    on_exit(fn ->
      _ = Supervisor.terminate_child(ReyCode.Supervisor, ReyCode.Web.Endpoint)
      _ = Supervisor.delete_child(ReyCode.Supervisor, ReyCode.Web.Endpoint)
    end)

    port = free_port()
    assert {:ok, pid} = Web.start(port)
    assert {:ok, ^pid} = Web.start(port)
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      )

    assert {:ok, "HTTP/1.1 404" <> _rest} = :gen_tcp.recv(socket, 0, 2_000)
  end

  test "a taken port names itself in the error" do
    assert Web.describe_error({:shutdown, {:listen, :eaddrinuse}}, 4747) =~
             "Port 4747 is already in use"

    assert Web.describe_error(:boom, 4747) =~ "Could not start ReyCode Desktop: :boom"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
