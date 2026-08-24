defmodule ReyCode.TUITest do
  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Orchestration.Squad
  alias ReyCode.Test.Wait

  test "renders a project room and posts a mode-tagged message" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    screen = Breeze.Test.render!(session)
    assert screen =~ "# reycode"
    assert screen =~ "Message #reycode"
    assert screen =~ "Workspace: #{File.cwd!()}"
    refute screen =~ "REYCODE"
    refute screen =~ "Search everything"
    baseline_sequence = ReyCode.snapshot().sequence

    for key <- String.graphemes("Compare this") do
      assert {:noreply, "prompt", true} = Breeze.Test.input(session, key)
    end

    assert {:noreply, "timeline-room-reycode", true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "timeline-room-reycode", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders?(session, "smallest end-to-end implementation", baseline_sequence)
    assert Breeze.Test.render!(session) =~ "Compare this"
  end

  test "creates and switches to a new project room" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, "new-room-name", true} = Breeze.Test.input(session, ctrl("n"))
    create_screen = Breeze.Test.render!(session)
    assert create_screen =~ "Create a project room"
    assert create_screen =~ File.cwd!()
    assert {:noreply, "new-room-name", false} = Breeze.Test.input(session, ctrl("n"))

    for key <- String.graphemes("Platform Work") do
      assert {:noreply, "new-room-name", _changed?} = Breeze.Test.input(session, key)
    end

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "# platform-work"
    assert screen =~ "Platform Work"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("o"))
    assert Breeze.Test.render!(session) =~ "debate"
  end

  test "shows the room's untruncated workspace from the slash palette" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/workspace")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Room workspace"
    assert screen =~ File.cwd!()
    assert get_in(Breeze.Test.metadata(session).assigns, [:modal]) == :workspace

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    refute Breeze.Test.render!(session) =~ "Room workspace"
  end

  test "confirms and cancels the selected room's running turn" do
    %{engine: engine, room_id: room_id} = start_isolated_stack(agent_delay_ms: 5_000)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Cancel this owner run", :compare, engine)

    assert wait_until_turn_status(engine, turn_id, :running)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/cancel")
    assert Breeze.Test.render!(session) =~ "Cancel the running turn"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :cancel
    assert Breeze.Test.render!(session) =~ "Cancel running turn"
    assert Breeze.Test.render!(session) =~ turn_id

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert wait_until_turn_status(engine, turn_id, :cancelled)
    assert Breeze.Test.render!(session) =~ "Turn cancelled"
  end

  test "renders the most recent squad run in the status dashboard" do
    session = start_session({120, 60})
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = squad_projection()
    assert {:noreply, _focused} = Breeze.Test.info(session, {:projection_snapshot, projection})

    type(session, "/status")
    assert Breeze.Test.render!(session) =~ "Open the squad status dashboard"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = session |> Breeze.Test.render!() |> plain()

    assert Breeze.Test.metadata(session).assigns.modal == :squad_dashboard
    assert screen =~ "Squad status"
    assert screen =~ "story_gate  /  cycle 0"
    assert screen =~ "15 tokens / 1 measured invocations / $0.0025"
    assert screen =~ "story_gate / cycle 0 / approve"
    assert screen =~ "stories / story_review / cycle 0"
    assert screen =~ "Three owner stories are ready for implementation."
    assert screen =~ "story_review / reviewer / attempt 2 / provider_retry"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")
    refute Breeze.Test.render!(session) =~ "Squad status"
  end

  test "adds a directive to the running squad and shows it in status" do
    %{engine: engine, room_id: room_id} =
      start_isolated_stack(simulator_opts: [delay_ms: 60_000, seed: 654])

    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, engine)
    assert {:ok, turn_id} = Engine.post_message(room_id, "Steer from the TUI", :squad, engine)

    on_exit(fn ->
      if GenServer.whereis(engine), do: Engine.cancel_turn(turn_id, "test cleanup", engine)
    end)

    session = start_session({120, 60}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/direct")
    assert Breeze.Test.render!(session) =~ "Steer the running squad"
    assert {:noreply, "directive-text", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :directive

    type(session, "Keep the release read-only")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    assert [directive] = Engine.snapshot(engine).turns[turn_id].squad.directives
    assert directive.text == "Keep the release read-only"
    assert Breeze.Test.render!(session) =~ "Squad directive added"

    type(session, "/status")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "OWNER DIRECTIVES"
    assert screen =~ "Keep the release read-only"
  end

  test "reviews and approves the held release gate" do
    context = start_isolated_stack(squad_release_gate_human: true)
    %{engine: engine, room_id: room_id} = context

    role_ids = Enum.map(Squad.roles(), & &1.id)
    :ok = Engine.configure_squad_roles(room_id, role_ids, :simulator, nil, engine)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Approve from the TUI", :squad, engine)

    wait_for_pending_review(engine, turn_id)

    on_exit(fn ->
      case GenServer.whereis(engine) do
        pid when is_pid(pid) -> Engine.cancel_turn(turn_id, "test cleanup", engine)
        _ -> :ok
      end
    end)

    session = start_session({120, 60}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert Breeze.Test.render!(session) =~ "release approval required"
    type(session, "/release")
    assert Breeze.Test.render!(session) =~ "Review the release gate"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Release gate review"
    assert screen =~ "LEADER RECOMMENDATION"
    assert screen =~ "approve"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "a")
    assert wait_until_turn_status(turn_id, :completed)
    assert Breeze.Test.render!(session) =~ "Release approved"
  end

  test "keeps the room timeline and composer available in a narrow terminal" do
    room_id = default_room_id()
    assert {:ok, turn_id} = ReyCode.post_message(room_id, "Narrow room", :compare)
    wait_until_terminal(turn_id)

    session = start_session({50, 20})
    on_exit(fn -> Breeze.Test.stop(session) end)

    screen = Breeze.Test.render!(session)
    assert screen =~ "# reycode"
    assert screen =~ "Ask the room"

    assert {:noreply, "timeline-room-reycode", true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Tab")

    type(session, "/")
    palette_screen = Breeze.Test.render!(session)
    assert palette_screen =~ "/agents"
    assert palette_screen =~ "Message #reycode"
    assert palette_screen =~ "Ctrl+P commands"
  end

  test "opens the truthful agent configuration flow" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("g"))
    assert Breeze.Test.render!(session) =~ "Who should use this runtime?"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("r"))
    assert Breeze.Test.render!(session) =~ "Who should use this runtime?"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("n"))
    refute Breeze.Test.render!(session) =~ "Create a project room"

    assert {:noreply, _focused, true} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Select a runtime"
    assert screen =~ "OpenCode"
    refute screen =~ "Demo"
    assert screen =~ "Provider discovery is disabled"
  end

  test "keeps the settings flow usable at narrow and wide terminal sizes" do
    narrow = start_session({50, 20})
    wide = start_session({160, 32})
    on_exit(fn -> Breeze.Test.stop(narrow) end)
    on_exit(fn -> Breeze.Test.stop(wide) end)

    for session <- [narrow, wide] do
      assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("g"))
      assert Breeze.Test.render!(session) =~ "Who should use this runtime?"

      assert {:noreply, _focused, true} = Breeze.Test.input(session, "Enter")
      assert Breeze.Test.render!(session) =~ "Select a runtime"
    end
  end

  test "lists DeepSeek as an API runtime and points to its key on selection" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("g"))
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")

    screen = Breeze.Test.render!(session)
    assert screen =~ "Select a runtime"
    assert screen =~ "OpenCode"
    assert screen =~ "DeepSeek"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert Breeze.Test.render!(session) =~ "Provider discovery is disabled"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "DEEPSEEK_API_KEY"
  end

  test "shows the sidebar only when the terminal is genuinely wide" do
    medium = start_session({120, 32})
    wide = start_session({160, 32})
    on_exit(fn -> Breeze.Test.stop(medium) end)
    on_exit(fn -> Breeze.Test.stop(wide) end)

    medium_screen = Breeze.Test.render!(medium)
    wide_screen = Breeze.Test.render!(wide)

    refute medium_screen =~ "REYCODE"
    assert medium_screen =~ "Ctrl+S send"
    refute medium_screen =~ ~r/\bF\d+\b/

    assert wide_screen =~ "REYCODE"
    assert wide_screen =~ "Ctrl+N new"
    refute wide_screen =~ "Search everything"
  end

  test "cycles wide focus through prompt, rooms, timeline, and prompt exactly" do
    session = start_session({160, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert Breeze.Test.metadata(session).focused == "prompt"
    assert {:noreply, "rooms", true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "timeline-room-reycode", true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Tab")
  end

  test "exposes only the selected Ctrl actions as global shortcuts" do
    keys = Enum.map(ReyCode.TUI.global_keybindings(), &elem(&1, 0))

    assert keys == ["Tab", "^N", "^O", "^P", "^S", "^R", "^G", "^T", "^Q"]
    refute Enum.any?(keys, &String.starts_with?(&1, "F"))
  end

  test "contains long provider failures and keeps the composer visible" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = failed_projection()

    assert {:noreply, _focused} = Breeze.Test.info(session, {:projection_snapshot, projection})

    screen = session |> Breeze.Test.render!() |> plain()
    lines = String.split(screen, "\n")
    author_line = Enum.find_index(lines, &String.contains?(&1, "[B]Builder"))
    error_line = Enum.find_index(lines, &String.contains?(&1, "10 minutes"))

    assert screen =~ "independent response"
    assert screen =~ "OpenCode did not finish within 10 minutes"
    refute screen =~ "second diagnostic line"
    assert screen =~ "Ask the room"
    assert error_line - author_line <= 3
    assert Enum.all?(lines, &(String.length(&1) <= 120))
  end

  test "opens an OpenCode-style palette above the composer when a draft starts with /" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/mod")

    rendered = Breeze.Test.render!(session)
    screen = plain(rendered)
    assert screen =~ "/mode"
    assert screen =~ "/models"
    assert screen =~ "Change orchestration mode"
    assert screen =~ "Message #reycode"
    assert screen =~ "Ctrl+P commands"
    refute screen =~ "ReyCode commands"
    assert rendered =~ "\e[48;2;125;211;167;38;2;11;14;18m /mode"

    mode_line = screen |> String.split("\n") |> Enum.find(&String.contains?(&1, "/mode"))
    assert mode_line =~ ~r/\/mode\s+Change orchestration mode/
    refute mode_line =~ ">"
  end

  test "moves the palette selection and runs a command" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/mod")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Configure room agents"
    assert Breeze.Test.render!(session) =~ "Who should use this runtime?"
  end

  test "tab completes the slash prefix" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/mo")

    assert Breeze.Test.render!(session) =~ "/mode"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Tab")
    metadata = Breeze.Test.metadata(session)
    assert get_in(metadata.assigns, [:slash, :query]) == "/mode"
    assert Breeze.Test.render!(session) =~ "/mode"
  end

  test "escape closes the palette and restores the draft" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/mod")

    assert Breeze.Test.render!(session) =~ "Change orchestration mode"
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    screen = Breeze.Test.render!(session)
    refute screen =~ "Change orchestration mode"
    assert screen =~ "/mod"
  end

  test "Ctrl+P opens commands and Escape restores the existing draft" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "Keep this draft")

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("p"))
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.modal == :slash
    assert metadata.assigns.slash.query == "/"
    assert metadata.assigns.drafts["room-reycode"] == "/"

    screen = Breeze.Test.render!(session)
    assert screen =~ "/agents"
    assert screen =~ "Message #reycode"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.drafts["room-reycode"] == "Keep this draft"
    assert Breeze.Test.render!(session) =~ "Keep this draft"
  end

  test "an unknown slash command is never posted to the room" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/bogus")

    assert Breeze.Test.render!(session) =~ "No matching commands"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Unknown command"
    refute screen =~ "No matching commands"
    assert get_in(Breeze.Test.metadata(session).assigns, [:drafts]) == %{"room-reycode" => ""}
  end

  test "runs a slash command with the prompt shortcut" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/te")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    refute screen =~ "ReyCode commands"
  end

  test "selects squad mode from the slash palette" do
    session = start_session({160, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/squad")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")

    assert Breeze.Test.metadata(session).assigns.mode == :squad
    screen = Breeze.Test.render!(session)
    refute screen =~ "ReyCode commands"
    assert screen =~ "SQUAD ROLES"
    assert screen =~ "Squad Leader"
    assert screen =~ "Senior Implementer"
    refute screen =~ "Demo"
  end

  defp start_isolated_stack(config_overrides) do
    {agent_delay_ms, config_overrides} = Keyword.pop(config_overrides, :agent_delay_ms, 0)
    {simulator_opts, config_overrides} = Keyword.pop(config_overrides, :simulator_opts)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tui_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    suffix = System.unique_integer([:positive])

    agent_registry = :"tui_agent_#{suffix}"
    event_registry = :"tui_events_#{suffix}"
    agent_supervisor = :"tui_sup_#{suffix}"

    start_supervised!({Registry, keys: :unique, name: agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_supervisor})

    config = configured_runtime(config_overrides)

    engine = :"tui_engine_#{suffix}"

    opts = [
      name: engine,
      event_store: store,
      agent_supervisor: agent_supervisor,
      agent_registry: agent_registry,
      event_registry: event_registry,
      provider_catalog: ReyCode.Provider.Catalog,
      agent_delay_ms: agent_delay_ms,
      simulator_opts: simulator_opts,
      config: config
    ]

    start_supervised!(Supervisor.child_spec({Engine, opts}, restart: :temporary))

    projection = Engine.subscribe(engine)
    room_id = List.first(projection.room_order)

    %{engine: engine, store: store, room_id: room_id}
  end

  defp wait_for_pending_review(server, turn_id, attempts \\ 400)

  defp wait_for_pending_review(_server, _turn_id, 0), do: flunk("no pending review")

  defp wait_for_pending_review(server, turn_id, attempts) do
    turn = Engine.snapshot(server).turns[turn_id]

    if turn && Map.get(turn.squad || %{}, :pending_review) do
      :ok
    else
      Process.sleep(25)
      wait_for_pending_review(server, turn_id, attempts - 1)
    end
  end

  defp type(session, text) do
    Breeze.Test.render!(session)

    for key <- String.graphemes(text) do
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, key)
      Breeze.Test.render!(session)
    end
  end

  defp start_session(size, opts \\ []) do
    Breeze.Test.start!(ReyCode.TUI,
      size: size,
      theme: ReyCode.Theme.default(),
      global_keybindings: ReyCode.TUI.global_keybindings(),
      start_opts: Keyword.take(opts, [:engine])
    )
  end

  defp default_room_id do
    snapshot = ReyCode.snapshot()
    Enum.find(snapshot.room_order, &(snapshot.rooms[&1].slug == "reycode"))
  end

  defp ctrl(key), do: %{"ctrlKey" => true, "key" => key}

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  defp failed_projection do
    projection = ReyCode.snapshot()
    room_id = default_room_id()
    room = projection.rooms[room_id]
    message_id = "msg-ui-failure"
    invocation_id = "inv-ui-failure"
    turn_id = "turn-ui-failure"

    message = %{
      id: message_id,
      room_id: room_id,
      turn_id: turn_id,
      invocation_id: invocation_id,
      author: %{kind: :agent, id: "builder", name: "Builder"},
      role: :assistant,
      status: :failed,
      body: "",
      created_at: "2026-08-04T13:00:00Z",
      created_sequence: projection.sequence,
      error: %{
        "message" =>
          "OpenCode did not finish within 600000ms\nsecond diagnostic line that should not render"
      }
    }

    invocation = %{
      id: invocation_id,
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "pragmatic implementation",
        provider: :opencode,
        model: "openai/gpt-5.4-mini"
      },
      label: "independent response",
      status: :failed
    }

    projection
    |> put_in([:rooms, room_id], %{room | message_order: [message_id]})
    |> put_in([:messages, message_id], message)
    |> put_in([:invocations, invocation_id], invocation)
  end

  defp squad_projection do
    projection = ReyCode.snapshot()
    room_id = default_room_id()
    room = projection.rooms[room_id]
    turn_id = "turn-ui-squad-dashboard"
    invocation_id = "inv-ui-squad-dashboard"

    decision = %{
      role_id: "squad_leader",
      decision: "approve",
      phase: "story_gate",
      cycle: 0,
      target_phase: nil,
      reasons: ["Stories cover the requested owner outcome"]
    }

    artifact = %{
      role_id: "analyst",
      kind: "stories",
      phase: "story_review",
      cycle: 0,
      invocation_id: invocation_id,
      message_id: "msg-ui-squad-dashboard",
      summary: "Three owner stories are ready for implementation.",
      blockers: [],
      digest: "dashboard-digest"
    }

    retry = %{
      role_id: "reviewer",
      attempt: 2,
      kind: "provider_retry",
      phase: "story_review",
      cycle: 0,
      reason: "provider_failure"
    }

    turn = %{
      id: turn_id,
      room_id: room_id,
      user_message_id: "msg-ui-squad-owner",
      mode: :squad,
      status: :completed,
      context_through_sequence: projection.sequence,
      invocation_order: [invocation_id],
      outcome: :completed,
      squad: %{
        room_id: room_id,
        workflow_version: "squad-v3",
        stage: 3,
        phase: "story_gate",
        cycle: 0,
        rework_count: 0,
        rework_budget: 3,
        seats: Enum.map(Squad.roles(), & &1.id),
        decisions: [decision],
        latest_gate: decision,
        promotions: %{},
        artifacts: [artifact],
        blockers: [],
        retries: [retry],
        seed: 0
      },
      created_at: "9999-12-31T23:59:59Z"
    }

    invocation = %{
      id: invocation_id,
      usage: %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => 0.0025}
    }

    projection
    |> put_in([:rooms, room_id], %{room | active_turn_id: nil})
    |> put_in([:turns, turn_id], turn)
    |> put_in([:invocations, invocation_id], invocation)
  end

  defp wait_until_terminal(turn_id, attempts \\ 300),
    do: Wait.terminal_turn(Engine, turn_id, attempts * 10)

  defp wait_until_turn_status(turn_id, status),
    do: Wait.turn_status(Engine, turn_id, status, 1_000)

  defp wait_until_turn_status(server, turn_id, status),
    do: Wait.turn_status(server, turn_id, status, 1_000)

  defp configured_runtime(overrides) do
    keys = RuntimeConfig.declared_defaults() |> Map.keys()

    :rey_code
    |> Application.get_all_env()
    |> Keyword.take(keys)
    |> Keyword.merge(overrides)
    |> RuntimeConfig.fresh()
  end

  defp eventually_renders?(session, text, baseline_sequence, attempts \\ 300) do
    projection =
      Wait.projection(
        Engine,
        &projection_with_message(&1, text, baseline_sequence),
        attempts * 10
      )

    _reply = Breeze.Test.info(session, {:projection_snapshot, projection})
    Breeze.Test.render!(session) =~ text
  end

  defp projection_with_message(projection, text, baseline_sequence) do
    if Enum.any?(projection.messages, fn {_id, message} ->
         message.created_sequence > baseline_sequence and String.contains?(message.body, text)
       end),
       do: projection
  end
end
