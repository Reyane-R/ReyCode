defmodule ReyCode.Web.DesktopFlowTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Web

  @endpoint ReyCode.Web.Endpoint

  setup do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    {:ok, _pid} = Web.start(port)

    on_exit(fn ->
      _ = Supervisor.terminate_child(ReyCode.Supervisor, ReyCode.Web.Endpoint)
      _ = Supervisor.delete_child(ReyCode.Supervisor, ReyCode.Web.Endpoint)
    end)

    workspace = Path.join(System.tmp_dir!(), "desktop-flow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, session_id} = Engine.create_blank_session("Desktop flow", workspace)
    %{session_id: session_id, conn: build_conn() |> init_test_session(%{token: Web.token()})}
  end

  test "a browser without the token is turned away", %{session_id: session_id} do
    assert build_conn() |> get("/sessions/#{session_id}") |> response(403) =~ "access token"
  end

  test "sending from the composer goes through the Engine", %{conn: conn, session_id: id} do
    {:ok, view, html} = live(conn, "/sessions/#{id}")
    assert html =~ "Desktop flow"

    view |> form("#composer", body: "hello from the browser") |> render_submit()

    assert render(view) =~ "hello from the browser"
    snapshot = Engine.snapshot()
    # message_order is newest first, so the Operator's message is the oldest.
    assert snapshot.messages[List.last(snapshot.sessions[id].message_order)].body ==
             "hello from the browser"
  end

  test "home starts a conversation in a known workspace", %{conn: conn, session_id: source} do
    workspace = Engine.snapshot().sessions[source].workspace
    {:ok, view, html} = live(conn, "/")
    assert html =~ "What should we work on?"

    view
    |> form("#start", body: "map the parser", workspace: workspace)
    |> render_submit()

    "/sessions/" <> new_id = assert_patch(view)
    refute new_id == source
    assert render(view) =~ "map the parser"
    assert Engine.snapshot().sessions[new_id].title == "map the parser"
  end

  test "blank messages are ignored", %{conn: conn, session_id: id} do
    {:ok, view, _html} = live(conn, "/sessions/#{id}")
    refute view |> form("#composer", body: "   ") |> render_submit() =~ "Could not send"
  end
end
