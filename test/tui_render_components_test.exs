defmodule ReyCode.TUI.RenderComponentsTest do
  use ExUnit.Case, async: false

  alias ReyCode.TUI.State

  defmodule ActiveSessionView do
    use Breeze.View
    @impl true
    def mount(opts, term) do
      {:ok, term} = ReyCode.TUI.mount(opts, term)
      {:ok, assign(term, home: false)}
    end

    @impl true
    def render(assigns), do: ReyCode.TUI.render(assigns)
    @impl true
    def handle_event(event, payload, term), do: ReyCode.TUI.handle_event(event, payload, term)
    @impl true
    def handle_info(message, term), do: ReyCode.TUI.handle_info(message, term)
  end

  test "home verification action is mouse-operable while Tab keeps the prompt focus policy" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {80, 24},
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    type(session, "keep this draft")
    # /verify appears in Quick start only once a model is connected.
    connect_simulator(session)
    id = Breeze.Test.metadata(session).assigns.selected_session_id
    Breeze.Test.input(session, "Tab")
    assert Breeze.Test.metadata(session).focused == "prompt"
    mouse_action(session, "/verify  Verify an isolated change", "release")
    assert Breeze.Test.metadata(session).assigns.modal == nil
    mouse_action(session, "/verify  Verify an isolated change")
    assert Breeze.Test.metadata(session).assigns.modal == :verification
    assert Breeze.Test.metadata(session).focused == "verify-goal"
    assert Breeze.Test.metadata(session).assigns.verification.goal == "keep this draft"
    Breeze.Test.input(session, "Escape")
    Breeze.Test.input(session, "Tab")
    assert Breeze.Test.metadata(session).focused == "prompt"
    assert Breeze.Test.metadata(session).assigns.drafts[id] == "keep this draft"
  end

  test "persistent verified summary does not steal focus and separates Ready from Applied" do
    session =
      Breeze.Test.start!(ActiveSessionView,
        size: {60, 24},
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render!(session)
    type(session, "scratch")
    metadata = Breeze.Test.metadata(session)
    id = metadata.assigns.selected_session_id
    projection = metadata.assigns.projection

    change = %ReyCode.Orchestration.VerifiedChange{
      id: "change-summary",
      phase: "ready",
      commands: ["true"],
      baseline: [],
      checks: [],
      repair_count: 0,
      max_repair_count: 1,
      patch: "",
      patch_hash: "hash",
      prompt: "goal",
      source_workspace: "/source",
      workspace: "/candidate",
      timeout_ms: 600_000,
      check_timeout_ms: 120_000
    }

    message = %ReyCode.Orchestration.Message{
      id: "history",
      session_id: id,
      role: :user,
      status: :completed,
      body: Enum.map_join(1..80, "\n\n", &"History line #{&1}"),
      created_at: "2026-09-08T10:00:00Z",
      created_sequence: projection.sequence
    }

    record = %{projection.sessions[id] | verified_change: change, message_order: [message.id]}

    projection = %{
      projection
      | sequence: projection.sequence + 1,
        sessions: Map.put(projection.sessions, id, record),
        messages: Map.put(projection.messages, message.id, message)
    }

    Breeze.Test.info(session, {:projection_snapshot, projection})
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Ready | baseline"
    assert screen =~ "repairs 0/1"
    assert screen =~ "Source not applied by ReyCode"
    assert Breeze.Test.metadata(session).focused == "prompt"
    assert Breeze.Test.metadata(session).assigns.drafts[id] == "scratch"

    Breeze.Test.input(session, "Tab")
    timeline_id = State.timeline_id(id)
    assert Breeze.Test.metadata(session).focused == timeline_id
    Breeze.Test.input(session, "Home")
    Breeze.Test.input(session, "PageDown")
    before_panel = session |> Breeze.Test.render!() |> plain()
    before_scroll = Map.fetch!(Breeze.Test.metadata(session).implicit_state, timeline_id)
    Breeze.Test.event(session, "verification_review", %{})
    Breeze.Test.input(session, "3")
    Breeze.Test.input(session, "a")
    Breeze.Test.input(session, "e")
    Breeze.Test.render!(session)
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.verification.tab == :patch
    assert Breeze.Test.metadata(session).assigns.verification.decision == nil
    Breeze.Test.input(session, "Escape")
    assert session |> Breeze.Test.render!() |> plain() == before_panel
    assert Breeze.Test.metadata(session).focused == timeline_id
    assert Map.fetch!(Breeze.Test.metadata(session).implicit_state, timeline_id) == before_scroll
    mouse_action(session, "/changes Review")
    assert Breeze.Test.render!(session) =~ "Verified change: Ready"
    Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.verification.decision == nil
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.drafts[id] == "scratch"

    resolution = %ReyCode.Orchestration.VerifiedChangeResolution{
      status: :applied,
      decision: :apply
    }

    record = %{record | verified_change_resolution: resolution}

    projection = %{
      projection
      | sequence: projection.sequence + 1,
        sessions: Map.put(projection.sessions, id, record)
    }

    Breeze.Test.info(session, {:projection_snapshot, projection})
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Applied | baseline"
    assert screen =~ "not rerun after integration"
    refute screen =~ "Source not applied by ReyCode"

    mouse_action(session, "/tools")
    assert Breeze.Test.metadata(session).assigns.notice.message =~ "No tool request"
    mouse_action(session, "/answer")
    assert Breeze.Test.metadata(session).assigns.notice.message =~ "No Operator question"

    record = %{
      record
      | verified_change: %{change | phase: "baseline"},
        verified_change_resolution: nil
    }

    projection = %{
      projection
      | sequence: projection.sequence + 1,
        sessions: Map.put(projection.sessions, id, record)
    }

    Breeze.Test.info(session, {:projection_snapshot, projection})
    mouse_action(session, "/cancel Stop")
    assert Breeze.Test.metadata(session).assigns.modal == :cancel
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.modal == nil
    assert Breeze.Test.metadata(session).assigns.drafts[id] == "scratch"
    Breeze.Test.input(session, "Tab")
    assert Breeze.Test.metadata(session).focused == timeline_id

    for target <- [
          "verification-review",
          "verification-cancel",
          "verification-tools",
          "verification-question",
          "prompt"
        ] do
      Breeze.Test.input(session, "Tab")
      assert Breeze.Test.metadata(session).focused == target
    end
  end

  test "multiline composer survives palette panels and shows Queue for a pending FollowUp" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {80, 24},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render!(session)
    type(session, "first line")
    Breeze.Test.input(session, %{"shiftKey" => true, "key" => "Enter"})
    type(session, "second line")
    assert Breeze.Test.render!(session) =~ "Enter Send"
    Breeze.Test.input(session, ctrl("p"))
    type(session, "hotkeys")
    Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :hotkeys
    Breeze.Test.input(session, "Escape")
    metadata = Breeze.Test.metadata(session)
    id = metadata.assigns.selected_session_id
    assert metadata.focused == "prompt"
    assert metadata.assigns.drafts[id] == "first line\nsecond line"
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "first line"
    assert screen =~ "second line"

    projection = metadata.assigns.projection

    queued = %ReyCode.Orchestration.Turn{
      id: "queued-composer",
      session_id: id,
      status: :queued,
      input_kind: :follow_up
    }

    record = %{projection.sessions[id] | queued_turn_ids: [queued.id]}

    projection = %{
      projection
      | sequence: projection.sequence + 1,
        sessions: Map.put(projection.sessions, id, record),
        turns: Map.put(projection.turns, queued.id, queued)
    }

    Breeze.Test.info(session, {:projection_snapshot, projection})
    screen = Breeze.Test.render!(session)
    assert screen =~ "Enter Queue"
    assert screen =~ "/steer"
  end

  test "composer events and new-session shortcut preserve prompt focus" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 32},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    Breeze.Test.render!(session)
    assert Breeze.Test.metadata(session).focused == "prompt"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Enter")

    assert Breeze.Test.metadata(session).assigns.notice == %ReyCode.TUI.Notice{
             severity: :info,
             message: "Write a message first"
           }

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "x")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "x"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("n"))
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.home == true
    assert metadata.assigns.drafts[session_id] == ""
    assert Breeze.Test.render!(session) =~ "AI workbench"
  end

  test "session header prioritizes useful work status over internal telemetry" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 32},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render!(session)

    engine = Breeze.Test.metadata(session).assigns.engine
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    projection = engine.snapshot()
    session_record = projection.sessions[session_id]

    turn_id = "turn-header-budget"
    invocation_id = "inv-header-budget"
    user_message_id = "msg-header-user"
    assistant_message_id = "msg-header-assistant"

    user_message = %{
      id: user_message_id,
      session_id: session_id,
      turn_id: nil,
      invocation_id: nil,
      author: %{kind: :user, id: "user", name: "You"},
      role: :user,
      status: :completed,
      body: "Inspect the header",
      created_at: "2026-08-24T20:00:00Z",
      created_sequence: projection.sequence,
      error: nil
    }

    assistant_message = %{
      id: assistant_message_id,
      session_id: session_id,
      turn_id: turn_id,
      invocation_id: invocation_id,
      author: %{kind: :agent, id: "assistant", name: "Assistant"},
      role: :assistant,
      status: :completed,
      body: "Done",
      created_at: "2026-08-24T20:00:01Z",
      created_sequence: projection.sequence,
      error: nil
    }

    long_workspace =
      "/opt/reycode-work/" <>
        Enum.map_join(1..10, "", &"directory-level-#{&1}/") <> "ReyCode"

    invocation = %{
      id: invocation_id,
      notes: [],
      participant: %{id: "assistant", name: "Assistant", provider: :simulator, model: "test"},
      session_id: session_id,
      turn_id: turn_id,
      status: :completed,
      attempt: 1,
      usage: %{"prompt_tokens" => 10, "completion_tokens" => 2},
      pending_tool_review: nil,
      delegated_from_invocation_id: nil,
      tool_runs: %{},
      tool_run_order: []
    }

    terminal_turn = %{
      mode: :direct,
      invocation_order: [invocation_id],
      status: :terminal,
      outcome: :completed,
      created_at: DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.to_iso8601()
    }

    session_order =
      Enum.reject(projection.session_order, &(&1 == session_id)) ++ [session_id]

    projection =
      %{projection | session_order: session_order}
      |> put_in([:sessions, session_id], %{
        session_record
        | active_turn_id: turn_id,
          workspace: long_workspace,
          message_order: [assistant_message_id, user_message_id]
      })
      |> put_in([:messages, user_message_id], user_message)
      |> put_in([:messages, assistant_message_id], assistant_message)
      |> put_in([:turns, turn_id], terminal_turn)
      |> put_in([:invocations, invocation_id], invocation)

    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = session |> Breeze.Test.render!() |> plain()

    assert screen =~ "✓ · Completed"
    assert screen =~ "Assistant"
    assert screen =~ "Message Assistant"
    refute screen =~ "EVT "
    refute screen =~ "TURN BUDGET TERMINAL"
    refute screen =~ "INV 01/01"
    refute screen =~ "GATE CLEAR"
    refute screen =~ "OUT COMPLETED"
    refute screen =~ long_workspace

    detached_dir =
      Path.join(System.tmp_dir!(), "rey-code-detached-\#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(detached_dir, ".git"))
    File.write!(Path.join(detached_dir, ".git/HEAD"), "0123456789abcdef0123456789abcdef\n")
    on_exit(fn -> File.rm_rf!(detached_dir) end)

    projection =
      put_in(projection, [:sessions, session_id, Access.key(:workspace)], detached_dir)

    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    assert session |> Breeze.Test.render!() |> plain() =~ "⑂ detached"

    checkout = File.cwd!()
    projection = put_in(projection, [:sessions, session_id, Access.key(:workspace)], checkout)
    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    assert session |> Breeze.Test.render!() |> plain() =~ "⑂ "

    long_ref_dir =
      Path.join(System.tmp_dir!(), "rey-code-longref-\#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(long_ref_dir, ".git"))

    File.write!(
      Path.join(long_ref_dir, ".git/HEAD"),
      "ref: refs/heads/feature/session-capability-pass\n"
    )

    on_exit(fn -> File.rm_rf!(long_ref_dir) end)

    projection = put_in(projection, [:sessions, session_id, Access.key(:workspace)], long_ref_dir)
    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    assert session |> Breeze.Test.render!() |> plain() =~ "⑂ feature/..."
  end

  test "terminal resize preserves drafts and reflows without crashing" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 32},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    Breeze.Test.render!(session)

    # First-run setup opens on top; close it so the composer takes input.
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "x")
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "x"

    resized_terminal = %{session.terminal | size: %{width: 80, height: 24}}
    # The resize dispatch already updated the view's terminal; render at the
    # new size to assert the reflow.
    screen = Breeze.Test.render!(session, terminal: resized_terminal)
    assert screen =~ "REYCODE"
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "x"
    assert Breeze.Test.metadata(session).focused == "prompt"
  end

  test "composer readiness states what the Assistant can do right now" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 32},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    unready = Breeze.Test.render!(session)
    assert unready =~ "Connect a model"

    providers = %{simulator: %{id: :simulator, status: :configured, models: ["test"]}}
    generation = Breeze.Test.metadata(session).assigns.providers_generation + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:provider_catalog_updated, %{generation: generation, providers: providers}}
             )

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    engine = Breeze.Test.metadata(session).assigns.engine
    projection = engine.snapshot()
    session_record = projection.sessions[session_id]

    participant =
      session_record.participants
      |> Enum.find(&(&1.kind == :primary))
      |> Map.merge(%{provider: :simulator, model: "test"})

    projection =
      put_in(
        projection,
        [:sessions, session_id, Access.key(:participants)],
        [participant | Enum.reject(session_record.participants, &(&1.kind == :primary))]
      )

    next_sequence = projection.sequence + 1

    assert {:noreply, _focused} =
             Breeze.Test.info(
               session,
               {:projection_snapshot, %{projection | sequence: next_sequence}}
             )

    screen = Breeze.Test.render!(session)
    assert screen =~ "Ready"
    refute screen =~ "Connect a model — /connect"
  end

  test "home screen leads with workspace and keeps essentials at small heights" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {80, 24},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Workspace"
    assert screen =~ "Browse commands"
    assert screen =~ "Message Assistant"
  end

  test "home content scrolls above the composer instead of painting over it" do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {80, 24},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")

    assigns = Breeze.Test.metadata(session).assigns
    projection = assigns.projection
    session_id = assigns.selected_session_id

    recent =
      for index <- 1..3 do
        %{
          id: "overflow-#{index}",
          title: "OVERFLOW-SESSION-#{index}",
          message_order: ["message-#{index}"],
          created_at: "2026-09-10T10:0#{index}:00Z",
          workspace: assigns.projection.sessions[session_id].workspace
        }
      end

    projection = %{
      projection
      | sequence: projection.sequence + 1,
        session_order: projection.session_order ++ Enum.map(recent, & &1.id),
        sessions: Map.merge(projection.sessions, Map.new(recent, &{&1.id, &1}))
    }

    assert {:noreply, _focused} = Breeze.Test.info(session, {:projection_snapshot, projection})

    lines =
      session
      |> Breeze.Test.render!()
      |> plain()
      |> String.split("\n")

    composer_top =
      Enum.find_index(lines, &String.contains?(&1, "Ask anything"))

    assert composer_top
    composer_region = Enum.slice(lines, max(composer_top - 1, 0)..-1//1)

    # The composer separator, label, input, and footer rows belong to the
    # composer alone; scrolled home rows must never paint over them.
    for line <- composer_region do
      refute line =~ "OVERFLOW-SESSION", "home row painted over the composer: #{inspect(line)}"
    end

    # Content taller than the viewport renders a scrollbar instead of
    # spilling into the composer.
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "▼"
  end

  defp ctrl(key), do: %{"ctrlKey" => true, "key" => key}

  # Marks the Primary Assistant ready so the home screen renders its full
  # quick-start set, mirroring the composer-readiness seam.
  defp connect_simulator(session) do
    providers = %{simulator: %{id: :simulator, status: :configured, models: ["test"]}}
    generation = Breeze.Test.metadata(session).assigns.providers_generation + 1

    {:noreply, _} =
      Breeze.Test.info(
        session,
        {:provider_catalog_updated, %{generation: generation, providers: providers}}
      )

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    projection = Breeze.Test.metadata(session).assigns.engine.snapshot()
    session_record = projection.sessions[session_id]

    participant =
      session_record.participants
      |> Enum.find(&(&1.kind == :primary))
      |> Map.merge(%{provider: :simulator, model: "test"})

    projection =
      put_in(
        projection,
        [:sessions, session_id, Access.key(:participants)],
        [participant | Enum.reject(session_record.participants, &(&1.kind == :primary))]
      )

    {:noreply, _} =
      Breeze.Test.info(
        session,
        {:projection_snapshot, %{projection | sequence: projection.sequence + 1}}
      )
  end

  defp mouse_action(session, label, action \\ "press") do
    {line, y} =
      session
      |> Breeze.Test.render!()
      |> plain()
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.find(fn {line, _y} -> String.contains?(line, label) end)

    {index, _length} = :binary.match(line, label)
    x = line |> binary_part(0, index) |> String.length()

    Breeze.Test.input(session, %{
      "mouse" => %{"button" => "left", "action" => action, "x" => x, "y" => y}
    })
  end

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  defp type(session, text) do
    Breeze.Test.render!(session)

    for key <- String.graphemes(text) do
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, key)
      Breeze.Test.render!(session)
    end
  end
end
