defmodule ReyCode.Web.SessionLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ReyCode.Orchestration.{
    Author,
    Invocation,
    Message,
    Participant,
    Projection,
    Session,
    ToolAsk
  }

  alias ReyCode.Web.{SessionLive, SessionsLive}

  defp projection(sequence) do
    message = %Message{
      id: "m1",
      author: %Author{kind: :agent, id: "a", name: "Assistant"},
      status: :streaming,
      body: "<b>hi</b>"
    }

    report = %Message{id: "m2", body: "Found 3 callers", created_sequence: 5}

    worker = %Invocation{
      id: "child",
      session_id: "s1",
      message_id: "m2",
      delegated_from_invocation_id: "parent",
      participant: %Participant{name: "Worker 1", model: "gpt-5"},
      status: :waiting_tool_approval,
      tool_run_order: ["r1", "r2"],
      pending_tool_review: %ToolAsk{
        request_id: "r2",
        tool: "merge",
        workspace: "/w",
        requested_at: nil,
        arguments: %{"diff" => "@@ -1 +1 @@\n-old\n+new"}
      }
    }

    %Projection{
      sequence: sequence,
      session_order: ["s1"],
      sessions: %{"s1" => %Session{id: "s1", title: "Fix parser", message_order: ["m1"]}},
      messages: %{"m1" => message, "m2" => report},
      invocations: %{"parent" => %Invocation{id: "parent", session_id: "s1"}, "child" => worker}
    }
  end

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}

  test "timeline renders escaped messages and ignores stale broadcasts" do
    {:noreply, socket} =
      SessionLive.handle_info(
        {:projection_snapshot, projection(2)},
        socket(%{id: "s1", sequence: 1})
      )

    html = rendered_to_string(SessionLive.render(socket.assigns))
    assert html =~ "Fix parser"
    assert html =~ "Assistant"
    assert html =~ "streaming"
    assert html =~ "&lt;b&gt;hi&lt;/b&gt;"
    assert html =~ "Worker 1"
    assert html =~ "needs you"
    assert html =~ "2 tool runs"
    assert html =~ "Found 3 callers"
    assert html =~ ~s(<span class="add">+new</span>)
    assert html =~ ~s(<span class="del">-old</span>)

    assert {:noreply, ^socket} =
             SessionLive.handle_info({:projection_snapshot, projection(2)}, socket)

    {:noreply, missing} =
      SessionLive.handle_info(
        {:projection_snapshot, projection(3)},
        socket(%{id: "nope", sequence: 0})
      )

    assert rendered_to_string(SessionLive.render(missing.assigns)) =~ "Session not found"
  end

  test "session list links each session" do
    {:noreply, socket} =
      SessionsLive.handle_info({:projection_snapshot, projection(1)}, socket(%{sequence: 0}))

    assert rendered_to_string(SessionsLive.render(socket.assigns)) =~ ~s(href="/sessions/s1")
  end
end
