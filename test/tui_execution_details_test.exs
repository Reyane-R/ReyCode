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
         answer_copy: Keyword.get(opts, :answer_copy, fn _ -> {:error, :test_unavailable} end),
         projection: %{
           sessions: %{"session" => %{message_order: Enum.map(messages, & &1.id)}},
           messages:
             Map.new(messages, &{&1.id, Map.merge(&1, %{turn_id: nil, invocation_id: nil})}),
           turns: %{},
           invocations: %{}
         }
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
          <.timeline
            messages={@messages}
            timeline_id="timeline"
            message_width={max(@breeze.terminal.width - 14, 1)}
            activity_frame="*"
            terminal_height={@breeze.terminal.height}
          />
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

    assert {:noreply, "copy-answer", _} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "execution-details-answer", _} = Breeze.Test.input(session, "Tab")
    Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Hide details"
    assert {:noreply, "prompt", _} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "timeline", _} = Breeze.Test.input(session, "Tab")
  end

  test "Copy is keyboard accessible and copies answer Markdown without thinking or controls" do
    owner = self()

    answer = %{
      message("answer", [%{kind: :note, text: "Private activity note"}])
      | body: "## Answer\n\n```elixir\n:ok\n```"
    }

    view =
      Breeze.Test.start!(TimelineView,
        size: {80, 30},
        global_keybindings: ReyCode.TUI.global_keybindings(),
        start_opts: [
          messages: [answer],
          answer_copy: fn text ->
            send(owner, {:copied, text})
            :ok
          end
        ]
      )

    on_exit(fn -> Breeze.Test.stop(view) end)
    assert Breeze.Test.render!(view) =~ "Copy"
    assert {:noreply, "copy-answer", _} = Breeze.Test.input(view, "Tab")
    Breeze.Test.input(view, "Enter")
    assert_receive {:copied, "## Answer\n\n```elixir\n:ok\n```"}
    assert Breeze.Test.metadata(view).assigns.notice.message == "Answer copied"
  end

  test "completed tools disclose explicitly without hiding the final response; thoughts remain capped" do
    notes = Enum.map(1..10, &%{kind: :note, text: "thought-#{&1}"})
    run = %{tool(:completed) | diff_lines: ["+changed line"], diff_truncated?: true}
    message = message("answer", notes ++ [run])
    session = start([message], 30)
    screen = Breeze.Test.render!(session)
    assert screen =~ "1 tool action"
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

  test "thinking-only replies have a truthful disclosure and empty replies have none" do
    thinking = start([message("thinking", [%{kind: :note, text: "Consider options"}])], 30)
    screen = Breeze.Test.render!(thinking)
    assert screen =~ "Thinking · Show details"
    refute screen =~ "0 tool actions"
    Breeze.Test.event(thinking, "execution_details_toggle", %{message_id: "thinking"})
    assert Breeze.Test.render!(thinking) =~ "Consider options"

    empty = start([message("empty", [])], 30)
    refute Breeze.Test.render!(empty) =~ "Show details"
  end

  test "message boundaries breathe on tall terminals and tighten on short ones" do
    user =
      message("user", [])
      |> Map.merge(%{role: :user, body: "First prompt", created_at: "2026-09-14T14:38:00Z"})

    next = %{user | id: "next", body: "Second prompt"}

    for {width, height} <- [{50, 24}, {80, 40}, {140, 40}] do
      session =
        Breeze.Test.start!(TimelineView,
          size: {width, height},
          start_opts: [messages: [user, message("reply", []), next]]
        )

      on_exit(fn -> Breeze.Test.stop(session) end)
      screen = Breeze.Test.render!(session)

      lines =
        screen
        |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
        |> String.split("\n")
        |> Enum.map(&String.trim/1)

      first = Enum.find_index(lines, &String.ends_with?(&1, "│ First prompt"))
      assistant = Enum.find_index(lines, &String.contains?(&1, "Assistant"))
      answer = Enum.find_index(lines, &String.ends_with?(&1, "Final response"))
      second = Enum.find_index(lines, &String.ends_with?(&1, "│ Second prompt"))

      assert is_integer(first) and is_integer(assistant) and is_integer(answer) and
               is_integer(second)

      assert assistant - first == 2
      assert answer - assistant == if(height >= 32, do: 2, else: 1)
      assert second - answer == if(height >= 32, do: 4, else: 3)
      assert screen =~ "Footer"
    end
  end

  test "reasoning wraps within the viewport rather than clipping its trailing words" do
    thought = Enum.map_join(1..24, " ", &"word#{&1}")
    answer = %{message("answer", [%{kind: :note, text: thought}]) | status: :streaming}

    for size <- [{50, 24}, {80, 30}] do
      view = Breeze.Test.start!(TimelineView, size: size, start_opts: [messages: [answer]])
      on_exit(fn -> Breeze.Test.stop(view) end)
      screen = Breeze.Test.render!(view)
      assert screen =~ "word24"
      lines = screen |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "") |> String.split("\n")
      assert Enum.count(lines, &String.contains?(&1, "word")) >= 3
    end
  end

  test "wide Unicode reasoning and long unbroken tokens wrap without losing characters" do
    thought = String.duplicate("界", 45) <> "TAIL"
    answer = %{message("answer", [%{kind: :note, text: thought}]) | status: :streaming}
    view = Breeze.Test.start!(TimelineView, size: {50, 24}, start_opts: [messages: [answer]])
    on_exit(fn -> Breeze.Test.stop(view) end)
    screen = Breeze.Test.render!(view)
    assert screen =~ "TAIL"
    assert length(String.split(screen, "界")) - 1 == 45
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
    # The scrollbar thumb legitimately shrinks as content grows below the
    # viewport; only the transcript column must stay put.
    without_scrollbar = fn screen ->
      screen |> String.split("\n") |> Enum.map_join("\n", &String.slice(&1, 0..-2//1))
    end

    before = session |> Breeze.Test.render!() |> without_scrollbar.()
    {_, scroll} = Breeze.Test.metadata(session).implicit_state["timeline"]
    refute scroll.pinned_bottom

    for count <- 1..3 do
      Breeze.Test.info(
        session,
        {:messages, [history, %{active | body: String.duplicate("Streaming\n\n", count)}]}
      )

      assert session |> Breeze.Test.render!() |> without_scrollbar.() == before

      assert Breeze.Test.metadata(session).implicit_state["timeline"] ==
               {Breeze.Implicit.Scroll, scroll}
    end

    Breeze.Test.info(session, {:messages, [history, message("answer", [tool(:completed)])]})
    assert session |> Breeze.Test.render!() |> without_scrollbar.() == before
    Breeze.Test.event(session, "execution_details_toggle", %{message_id: "answer"})
    assert session |> Breeze.Test.render!() |> without_scrollbar.() == before
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

  test "fenced code inside reasoning collapses to one row behind a single rail" do
    notes =
      Enum.map(
        ["Let me check the emitter.", "```ts", "const x = 1;", "```", "That fakes a node."],
        &%{kind: :note, text: &1}
      )

    active = %{message("answer", notes ++ [tool(:running)]) | status: :streaming}
    screen = [active] |> start(30) |> Breeze.Test.render!() |> plain()

    assert screen =~ "┆ Let me check the emitter."
    assert screen =~ "┆ code omitted"
    assert screen =~ "┆ That fakes a node."
    refute screen =~ "```"
    refute screen =~ "const x"
  end

  test "consecutive completed runs of one verb fold until details are expanded" do
    rows = [tool(:completed), tool(:completed), tool(:completed), tool(:running)]
    active = %{message("answer", rows) | status: :streaming}
    session = start([active], 30)
    screen = session |> Breeze.Test.render!() |> plain()

    assert screen =~ ~r/✓ Read ×3\s+secret\.ex, secret\.ex, secret\.ex/
    assert screen =~ "4 tool actions · Show details"

    Breeze.Test.event(session, "execution_details_toggle", %{message_id: "answer"})
    screen = session |> Breeze.Test.render!() |> plain()

    refute screen =~ "×3"
    assert length(Regex.scan(~r/✓ Read\s+secret\.ex/, screen)) == 3
    assert screen =~ "Hide details"
  end

  test "notes and answers holding broken bytes render instead of crashing" do
    broken = "1. " <> <<0xE2, 0x9C>>
    rows = [%{kind: :note, text: broken}, tool(:running)]
    active = %{message("answer", rows) | status: :streaming, body: "Body " <> broken}
    screen = [active] |> start(30) |> Breeze.Test.render!() |> plain()

    assert screen =~ "┆ 1. �"
    assert screen =~ "Body 1. �"
  end

  test "fenced code in the answer sits on the panel surface" do
    reply = %{message("answer", []) | body: "Intro\n\n```\ncode line\n```\n\nOutro"}
    lines = [reply] |> start(30) |> Breeze.Test.render!() |> String.split("\n")
    code = Enum.find(lines, &String.contains?(&1, "code line"))
    intro = Enum.find(lines, &String.contains?(&1, "Intro"))

    assert code =~ ~r/\e\[48;[^m]*m[^\e]*code line/
    refute intro =~ ~r/\e\[48;[^m]*m[^\e]*Intro/
  end

  defp plain(screen), do: String.replace(screen, ~r/\e\[[0-?]*[ -\/]*[@-~]/, "")

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
