defmodule ReyCode.Web.SessionLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ReyCode.Orchestration.{
    Author,
    Invocation,
    InvocationCoordination,
    Message,
    OperatorQuestion,
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

    report = %Message{id: "m2", invocation_id: "child", body: "Found 3 callers"}
    asking = %Message{id: "m3", invocation_id: "parent", body: ""}

    question =
      OperatorQuestion.from_map(%{
        id: "q1",
        tool_run_id: "ask",
        asked_at: nil,
        question: "Which parser?",
        recommended_id: "new",
        options: [
          %{id: "old", label: "Keep old", description: "", preview: ""},
          %{id: "new", label: "Use new", description: "faster", preview: ""}
        ],
        allow_other?: true
      })

    parent = %Invocation{
      id: "parent",
      session_id: "s1",
      turn_id: "t1",
      message_id: "m3",
      participant: %Participant{name: "Assistant"},
      pending_tool_review: %ToolAsk{
        request_id: "run-bash",
        tool: "bash",
        workspace: "/w",
        requested_at: nil,
        arguments: %{"command" => "mix test"}
      },
      coordination: %InvocationCoordination{pending_question: question}
    }

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
      sessions: %{
        "s1" => %Session{
          id: "s1",
          title: "Fix parser",
          workspace: "/w",
          active_turn_id: "t1",
          message_order: ["m2", "m3", "m1"]
        }
      },
      messages: %{"m1" => message, "m2" => report, "m3" => asking},
      invocations: %{"parent" => parent, "child" => worker}
    }
  end

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, notice: nil}, assigns)}

  test "timeline renders escaped messages and ignores stale broadcasts" do
    {:noreply, socket} =
      SessionLive.handle_info(
        {:projection_snapshot, projection(2)},
        socket(%{id: "s1", sequence: 1})
      )

    html = rendered_to_string(SessionLive.render(socket.assigns))
    assert html =~ "Fix parser"
    # Oldest first: the streaming "hi" (m1) is above the worker report (m2).
    [_above, timeline] = String.split(html, ~s(id="timeline"), parts: 2)
    assert :binary.match(timeline, "&lt;b&gt;hi") < :binary.match(timeline, "Found 3 callers")
    assert html =~ "Assistant"
    assert html =~ "streaming"
    assert html =~ "&lt;b&gt;hi&lt;/b&gt;"
    assert html =~ "Worker 1"
    assert html =~ "needs you"
    assert html =~ "2 tool runs"
    assert html =~ "Found 3 callers"
    assert html =~ ~s(<span class="add">+new</span>)
    assert html =~ ~s(<span class="del">-old</span>)
    assert html =~ ~s(phx-value-decision="apply")
    assert html =~ "Assistant wants to run <code>bash</code>"
    assert html =~ "mix test"
    assert html =~ ~s(phx-value-run="run-bash")
    assert html =~ "Which parser?"
    assert html =~ ~s(name="other-)
    assert html =~ "Queue a follow-up"
    assert html =~ "Stop"

    assert {:noreply, stale} =
             SessionLive.handle_event(
               "answer",
               %{"invocation" => "parent", "request" => "old-request"},
               socket
             )

    assert stale.assigns.notice =~ "already answered"

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
