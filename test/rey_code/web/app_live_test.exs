defmodule ReyCode.Web.AppLiveTest do
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
    ToolAsk,
    ToolRun,
    Turn
  }

  alias ReyCode.Web.AppLive

  defp projection(sequence) do
    message = %Message{
      id: "m1",
      author: %Author{kind: :agent, id: "a", name: "Assistant"},
      status: :streaming,
      body: "**hi** from `markdown`\n\n<script>alert(1)</script>"
    }

    report = %Message{id: "m2", invocation_id: "child", body: "Found 3 callers"}
    asking = %Message{id: "m3", invocation_id: "parent", body: "Let me check"}

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
      tool_run_order: ["run-read"],
      tool_runs: %{
        "run-read" => %ToolRun{
          id: "run-read",
          tool: "read",
          arguments: %{"path" => "/w/src/parser.ex"},
          status: :completed
        }
      },
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

  defp socket(assigns) do
    defaults = %{
      __changed__: %{},
      notice: nil,
      html_cache: %{},
      id: nil,
      filter: "",
      expanded: MapSet.new(),
      models: [],
      catalog_generation: 0
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(defaults, assigns)}
  end

  test "timeline renders escaped messages and ignores stale broadcasts" do
    {:noreply, socket} =
      AppLive.handle_info(
        {:projection_snapshot, projection(2)},
        socket(%{id: "s1", sequence: 1})
      )

    html = rendered_to_string(AppLive.render(socket.assigns))
    assert html =~ "Fix parser"
    [_above, rest] = String.split(html, ~s(id="timeline"), parts: 2)
    [timeline, _dock_and_rail] = String.split(rest, ~s(class="dock"), parts: 2)

    # Oldest first, markdown rendered, model HTML stripped.
    assert {first, _length} = :binary.match(timeline, "<strong>hi</strong>")
    assert {second, _length} = :binary.match(timeline, "Let me check")
    assert first < second

    refute html =~ "<script>alert"
    assert timeline =~ "<code>markdown</code>"
    assert timeline =~ "streaming"

    # Tool steps use the TUI's activity wording.
    assert timeline =~ ~s(<span class="tool-label">Read</span>)
    assert timeline =~ "parser.ex"

    # A worker's report lives in the workers rail, not the timeline.
    refute timeline =~ "Found 3 callers"
    assert html =~ "Worker 1"
    assert html =~ "Needs you"
    assert html =~ "gpt-5, 2 steps"
    assert html =~ ~s(<span class="add">+new</span>)
    assert html =~ ~s(<span class="del">-old</span>)
    assert html =~ ~s(phx-value-decision="apply")

    assert html =~ "wants to run <code>bash</code>"
    assert html =~ "mix test"
    assert html =~ ~s(phx-value-run="run-bash")
    assert html =~ "Which parser?"
    assert html =~ ~s(name="other-)
    assert html =~ "Add a follow-up"
    assert html =~ ~s(phx-click="stop")
    refute html =~ "Try again"

    assert {:noreply, stale} =
             AppLive.handle_event(
               "answer",
               %{"invocation" => "parent", "request" => "old-request"},
               socket
             )

    assert stale.assigns.notice =~ "already answered"

    # A current answer is built from the form and handed to the Engine; this
    # fixture's invocation is unknown to it, so the refusal surfaces as a notice.
    [item] = socket.assigns.question.request.questions

    for picked <- [%{"q-#{item.id}" => "new"}, %{"q-#{item.id}" => ["old", "new"]}, %{}] do
      params =
        Map.merge(
          %{"invocation" => "parent", "request" => "q1", "other-#{item.id}" => " custom "},
          picked
        )

      assert {:noreply, answered} = AppLive.handle_event("answer", params, socket)
      assert answered.assigns.notice =~ "Could not answer"
    end

    assert {:noreply, ^socket} =
             AppLive.handle_info({:projection_snapshot, projection(2)}, socket)

    {:noreply, missing} =
      AppLive.handle_info(
        {:projection_snapshot, projection(3)},
        socket(%{id: "nope", sequence: 0})
      )

    assert rendered_to_string(AppLive.render(missing.assigns)) =~ "no longer exists"
  end

  test "home lists sessions by workspace and offers a composer" do
    {:noreply, socket} =
      AppLive.handle_info({:projection_snapshot, projection(1)}, socket(%{sequence: 0}))

    html = rendered_to_string(AppLive.render(socket.assigns))
    assert html =~ ~s(href="/sessions/s1")
    assert html =~ "What should we work on?"
    assert html =~ ~s(<option value="/w">)
    assert html =~ "Search conversations"
    # Hidden until LiveView marks the root as disconnected.
    assert html =~ ~s(class="offline" role="status")
    assert html =~ ~s(class="dot")
  end

  test "a failed newest turn offers Try again once nothing is running" do
    failed = %Message{id: "f1", turn_id: "t9", body: "", status: :failed}

    projection = %Projection{
      sequence: 1,
      session_order: ["s1"],
      sessions: %{"s1" => %Session{id: "s1", workspace: "/w", message_order: ["f1"]}},
      messages: %{"f1" => failed},
      turns: %{"t9" => %Turn{id: "t9", outcome: :failed, status: :terminal}}
    }

    {:noreply, socket} =
      AppLive.handle_info({:projection_snapshot, projection}, socket(%{id: "s1", sequence: 0}))

    assert socket.assigns.retry_turn_id == "t9"
    assert rendered_to_string(AppLive.render(socket.assigns)) =~ "Try again"
  end

  test "search narrows the sidebar and older conversations collapse until expanded" do
    sessions =
      for n <- 1..7, into: %{} do
        {"s#{n}", %Session{id: "s#{n}", title: "task #{n}", workspace: "/w", message_order: []}}
      end

    projection = %Projection{
      sequence: 1,
      session_order: Enum.map(1..7, &"s#{&1}"),
      sessions: Map.put(sessions, "s7", %{sessions["s7"] | title: "parser bug"})
    }

    {:noreply, socket} =
      AppLive.handle_info({:projection_snapshot, projection}, socket(%{sequence: 0}))

    html = rendered_to_string(AppLive.render(socket.assigns))
    assert html =~ "Show 2 older"
    refute html =~ "task 1<"

    {:noreply, expanded} = AppLive.handle_event("expand", %{"workspace" => "/w"}, socket)
    refute rendered_to_string(AppLive.render(expanded.assigns)) =~ "Show 2 older"

    {:noreply, filtered} = AppLive.handle_event("filter", %{"filter" => " PARSER "}, socket)
    filtered_html = rendered_to_string(AppLive.render(filtered.assigns))
    assert filtered_html =~ "parser bug"
    refute filtered_html =~ "task 6"

    {:noreply, none} = AppLive.handle_event("filter", %{"filter" => "zzz"}, socket)
    assert rendered_to_string(AppLive.render(none.assigns)) =~ "No conversation matches"
  end

  test "the composer offers catalog models and rejects values the catalog never offered" do
    providers = %{
      openai: %{id: :openai, name: "OpenAI", status: :configured, models: ["gpt-5", "gpt-5-mini"]},
      off: %{id: :off, name: "Off", status: :unavailable, models: ["x"]}
    }

    {:noreply, socket} =
      AppLive.handle_info({:projection_snapshot, projection(2)}, socket(%{id: "s1", sequence: 1}))

    {:noreply, socket} =
      AppLive.handle_info(
        {:provider_catalog_updated, %{generation: 5, providers: providers}},
        socket
      )

    assert Enum.map(socket.assigns.models, & &1.value) == ["openai::gpt-5", "openai::gpt-5-mini"]
    html = rendered_to_string(AppLive.render(socket.assigns))
    assert html =~ ~s(id="model-picker")
    assert html =~ "OpenAI · gpt-5-mini"
    refute html =~ "Off · x"

    # A stale catalog broadcast is ignored.
    assert {:noreply, ^socket} =
             AppLive.handle_info(
               {:provider_catalog_updated, %{generation: 5, providers: %{}}},
               socket
             )

    {:noreply, rejected} = AppLive.handle_event("model", %{"model" => "evil::anything"}, socket)
    assert rejected.assigns.notice =~ "model unavailable"
  end
end
