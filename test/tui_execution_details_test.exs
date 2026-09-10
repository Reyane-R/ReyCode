defmodule ReyCode.TUI.ExecutionDetailsTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.{Activity, State}

  defmodule TimelineView do
    use Breeze.View
    import ReyCode.TUI.Components.MainScreen.Timeline

    @impl true
    def mount(opts, term) do
      messages = Keyword.fetch!(opts, :messages)

      {:ok,
       assign(term,
         messages: messages,
         modal: nil,
         selected_session_id: "session",
         expanded_message_ids: [],
         projection: %{sessions: %{"session" => %{message_order: Enum.map(messages, & &1.id)}}}
       )}
    end

    @impl true
    def render(assigns) do
      assigns =
        Map.update!(assigns, :messages, fn messages ->
          Enum.map(
            messages,
            &Map.put(&1, :execution_details_expanded?, &1.id in assigns.expanded_message_ids)
          )
        end)

      ~H"""
      <box class="w-screen h-screen">
        <box class="grid grid-cols-1 grid-rows-2 h-full w-full overflow-hidden">
          <.timeline messages={@messages} timeline_id="timeline" message_width={70} activity_frame="*"/>
          <box id="prompt" focusable class="h-1">Footer</box>
        </box>
      </box>
      """
    end

    @impl true
    def handle_event(event, payload, term), do: ReyCode.TUI.handle_event(event, payload, term)

    @impl true
    def handle_info({:messages, messages}, term), do: {:noreply, assign(term, messages: messages)}
  end

  test "application Tab binding reaches disclosure without requiring a mouse" do
    session =
      Breeze.Test.start!(TimelineView,
        size: {80, 24},
        global_keybindings: ReyCode.TUI.global_keybindings(),
        start_opts: [messages: [message("answer", [tool(:completed)])]]
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    assert Breeze.Test.render!(session) =~ "Show details"

    assert {:noreply, "execution-details-answer", _} = Breeze.Test.input(session, "Tab")
    Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Hide details"
    assert {:noreply, "prompt", _} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "timeline", _} = Breeze.Test.input(session, "Tab")
  end

  test "completed tools disclose explicitly without hiding the final response; thoughts remain capped" do
    notes = Enum.map(1..10, &%{kind: :note, text: "thought-#{&1}"})
    run = %{tool(:completed) | diff_lines: ["+changed line"], diff_truncated?: true}
    message = message("answer", notes ++ [run])
    session = start([message], 30)
    screen = Breeze.Test.render!(session)
    assert screen =~ "1 tool actions"
    assert screen =~ "Show details"
    assert screen =~ "Final response"
    refute screen =~ "secret.ex"
    refute screen =~ "thought-"
    refute screen =~ "+changed line"

    Breeze.Test.input(session, %{
      "mouse" => %{"button" => "left", "action" => "press", "x" => 5, "y" => 2}
    })

    screen = Breeze.Test.render!(session)
    assert screen =~ "Hide details"
    assert screen =~ "secret.ex"
    assert screen =~ "+2 earlier thoughts"
    refute screen =~ "thought-1 "
    assert screen =~ "thought-3"
    assert screen =~ "+changed line"
    assert screen =~ "Diff preview truncated"

    Breeze.Test.input(session, "Enter")
    refute Breeze.Test.render!(session) =~ "secret.ex"
    Breeze.Test.input(session, " ")
    assert Breeze.Test.render!(session) =~ "Hide details"
  end

  test "active, failed, denied and blocked executions never disappear" do
    for status <- [:running, :failed, :denied, :awaiting_approval] do
      message = message("answer", [tool(status)])
      session = start([message], 20)
      screen = Breeze.Test.render!(session)

      assert screen =~
               if(status == :awaiting_approval, do: "approval required", else: "secret.ex")

      refute screen =~ "Show details"
    end

    failed = %{message("failed", [tool(:completed)]) | status: :failed, error: "Provider failed"}
    session = start([failed], 20)
    assert Breeze.Test.render!(session) =~ "Provider failed"
    assert Breeze.Test.render!(session) =~ "secret.ex"
  end

  test "streaming and completion below an older viewport preserve scroll; End resumes following" do
    history = %{message("history", []) | body: Enum.map_join(1..60, "\n\n", &"History #{&1}")}
    active = %{message("answer", [tool(:running)]) | status: :streaming}
    session = start([history, active], 15)
    Breeze.Test.render!(session)
    Breeze.Test.input(session, "Home")
    Breeze.Test.input(session, "PageDown")
    before = Breeze.Test.render!(session)
    {_, scroll} = Breeze.Test.metadata(session).implicit_state["timeline"]
    refute scroll.pinned_bottom

    for count <- 1..3 do
      Breeze.Test.info(
        session,
        {:messages, [history, %{active | body: String.duplicate("Streaming\n\n", count)}]}
      )

      assert Breeze.Test.render!(session) == before

      assert Breeze.Test.metadata(session).implicit_state["timeline"] ==
               {Breeze.Implicit.Scroll, scroll}
    end

    Breeze.Test.info(session, {:messages, [history, message("answer", [tool(:completed)])]})
    assert Breeze.Test.render!(session) == before
    Breeze.Test.event(session, "execution_details_toggle", %{message_id: "answer"})
    assert Breeze.Test.render!(session) == before
    Breeze.Test.input(session, "End")
    assert Breeze.Test.render!(session) =~ "Final response"
    {_, following} = Breeze.Test.metadata(session).implicit_state["timeline"]
    assert following.pinned_bottom

    Breeze.Test.info(
      session,
      {:messages, [history, %{active | body: "Newest streamed response"}]}
    )

    assert Breeze.Test.render!(session) =~ "Newest streamed response"
  end

  test "disclosure IDs are bounded, reject foreign IDs, and clear on session navigation" do
    term = %{
      assigns: %{
        selected_session_id: "session",
        expanded_message_ids: [],
        projection: %{sessions: %{"session" => %{message_order: Enum.map(1..129, &to_string/1)}}}
      }
    }

    assert State.toggle_execution_details(term, "foreign") == term
    expanded = Enum.reduce(1..129, term, &State.toggle_execution_details(&2, to_string(&1)))
    assert length(expanded.assigns.expanded_message_ids) == 128
    refute "1" in expanded.assigns.expanded_message_ids
    assert State.select_session(expanded, "session").assigns.expanded_message_ids == []
  end

  defp start(messages, height) do
    session =
      Breeze.Test.start!(TimelineView, size: {80, height}, start_opts: [messages: messages])

    on_exit(fn -> Breeze.Test.stop(session) end)
    session
  end

  defp message(id, rows) do
    %{
      id: id,
      kind: :message,
      role: :assistant,
      author: %{name: "Assistant"},
      status: :completed,
      activity: nil,
      invocation: nil,
      body: "Final response",
      error: nil,
      execution_rows: rows,
      hidden_trace_note_count: 0
    }
  end

  defp tool(status) do
    %{id: "run", tool: "read", status: status, arguments: %{"path" => "/workspace/secret.ex"}}
    |> Activity.tool("/workspace", 0)
    |> Map.put(:diff_lines, [])
    |> Map.put(:diff_truncated?, false)
  end
end
