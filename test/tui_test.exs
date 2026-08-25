defmodule ReyCode.TUITest do
  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.State

  test "starts clean and creates a fresh durable session for the first message" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    source_session_id = Breeze.Test.metadata(session).assigns.selected_room_id
    screen = Breeze.Test.render!(session)
    assert screen =~ "Welcome to ReyCode"
    assert screen =~ "One assistant by default"
    assert screen =~ "Recent sessions"
    assert screen =~ "Ask anything…"
    assert screen =~ "/ for commands"
    refute screen =~ "You  ·"
    refute screen =~ "# reycode"
    baseline_sequence = ReyCode.snapshot().sequence

    type(session, "Handle this directly")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders?(session, "Handle this directly", baseline_sequence)

    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.selected_room_id != source_session_id

    session_room = ReyCode.snapshot().rooms[metadata.assigns.selected_room_id]
    assert session_room.title == "Handle this directly"
    session_screen = Breeze.Test.render!(session)
    assert session_screen =~ "ReyCode"
    assert session_screen =~ "Handle this directly"
    refute session_screen =~ "#"
  end

  test "/new starts another clean durable session" do
    %{engine: engine, room_id: session_id} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    first_baseline = Engine.snapshot(engine).sequence
    type(session, "First session message")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders_on?(session, engine, "First session message", first_baseline)
    first_session_id = Breeze.Test.metadata(session).assigns.selected_room_id

    type(session, "/new")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Welcome to ReyCode"

    second_baseline = Engine.snapshot(engine).sequence
    type(session, "Second session message")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders_on?(session, engine, "Second session message", second_baseline)

    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.selected_room_id != first_session_id

    screen = Breeze.Test.render!(session)
    assert screen =~ "Second session message"
    refute screen =~ "First session message"
  end

  test "! runs an owner shell command into a new session transcript" do
    %{engine: engine, room_id: session_id} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    baseline = Engine.snapshot(engine).sequence
    type(session, "!echo tier-one-owner")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    assert eventually_renders_on?(session, engine, "tier-one-owner", baseline)

    room_id = Breeze.Test.metadata(session).assigns.selected_room_id
    room = Engine.snapshot(engine).rooms[room_id]
    assert room.title == "echo tier-one-owner"

    assert Enum.any?(room.message_order, fn id ->
             String.contains?(Engine.snapshot(engine).messages[id].body, "! echo tier-one-owner")
           end)
  end

  test "Escape cancels the running turn" do
    %{engine: engine, room_id: room_id} = start_isolated_stack(agent_delay_ms: 5_000)

    assert {:ok, turn_id} = Engine.post_message(room_id, "Escape me", :direct, engine)
    assert wait_until_turn_status(engine, turn_id, :running)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("r"))

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")
    assert wait_until_turn_status(engine, turn_id, :cancelled)
    assert Breeze.Test.render!(session) =~ "Task cancelled"
  end

  test "/model switches the Assistant model from the catalog in one step" do
    %{engine: engine, room_id: session_id} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    providers = %{
      simulator: %{id: :simulator, name: "Simulator", status: :configured, models: []}
    }

    assert {:noreply, _focused} = push_providers(session, providers)

    type(session, "/model")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Assistant model"
    assert Breeze.Test.render!(session) =~ "Simulator"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Model set to Simulator"

    room_id = Breeze.Test.metadata(session).assigns.selected_room_id

    primary =
      Enum.find(Engine.snapshot(engine).rooms[room_id].participants, &(&1.kind == :primary))

    assert primary.provider == :simulator
  end

  test "/model rejects when no provider is configured" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, _focused} = push_providers(session, %{})

    type(session, "/model")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "No providers configured"
  end

  test "shows the untruncated workspace from the command palette" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)
    metadata = Breeze.Test.metadata(session)

    expected_workspace =
      metadata.assigns.projection.rooms[metadata.assigns.selected_room_id].workspace

    type(session, "/workspace")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Workspace"
    assert screen =~ expected_workspace
    assert get_in(Breeze.Test.metadata(session).assigns, [:modal]) == :workspace

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    refute Breeze.Test.render!(session) =~ "WORKSPACE PATH"
  end

  test "confirms and cancels the current session task" do
    %{engine: engine, room_id: room_id} = start_isolated_stack(agent_delay_ms: 5_000)

    assert {:ok, turn_id} =
             Engine.post_message(room_id, "Cancel this owner run", :compare, engine)

    assert wait_until_turn_status(engine, turn_id, :running)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/cancel")
    assert Breeze.Test.render!(session) =~ "Cancel the current task"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :cancel
    assert Breeze.Test.render!(session) =~ "Cancel current task"
    assert Breeze.Test.render!(session) =~ turn_id

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert wait_until_turn_status(engine, turn_id, :cancelled)
    assert Breeze.Test.render!(session) =~ "Task cancelled"
  end

  test "keeps the session home and command palette usable in a narrow terminal" do
    session = start_session({50, 20})
    on_exit(fn -> Breeze.Test.stop(session) end)

    screen = Breeze.Test.render!(session)
    assert screen =~ "Welcome to ReyCode"
    assert screen =~ "Ask anything…"

    type(session, "/")
    palette_screen = Breeze.Test.render!(session)
    assert palette_screen =~ "/agents"
    assert palette_screen =~ "/new"
  end

  test "creates a task agent before selecting its provider and model" do
    %{engine: engine, room_id: room_id} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/agent")
    assert {:noreply, "agent-name", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Create a task agent"

    type(session, "Release")
    assert {:noreply, "agent-responsibility", _changed?} = Breeze.Test.input(session, "Enter")

    type(session, "Commit, push, and deploy approved changes")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")

    screen = Breeze.Test.render!(session)
    assert screen =~ "Select a runtime"

    [participant_id] = Breeze.Test.metadata(session).assigns.settings.participant_ids

    participant =
      Engine.snapshot(engine).rooms[room_id].participants |> Enum.find(&(&1.id == participant_id))

    assert participant.name == "Release"
    assert participant.perspective == "Commit, push, and deploy approved changes"
    assert participant.kind == :task
  end

  test "delegates one task to one configured task agent" do
    %{engine: engine, room_id: room_id} = start_isolated_stack([])

    assert {:ok, participant_id} =
             Engine.add_task_participant(
               room_id,
               "Tests",
               "Run the relevant tests and report failures",
               engine
             )

    assert :ok =
             Engine.configure_participants(room_id, participant_id, :simulator, nil, engine)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)
    baseline_sequence = Engine.snapshot(engine).sequence

    type(session, "/task")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")

    selection_screen = Breeze.Test.render!(session)
    assert selection_screen =~ "Delegate a task"
    assert selection_screen =~ "Tests"

    assert {:noreply, "delegated-task", _changed?} = Breeze.Test.input(session, "Enter")
    type(session, "Run the focused test suite")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    assert eventually_renders_on?(
             session,
             engine,
             "Run the focused test suite",
             baseline_sequence
           )

    turn =
      Engine.snapshot(engine).turns
      |> Map.values()
      |> Enum.find(&(&1.participant_id == participant_id))

    assert turn.mode == :delegate
    assert length(turn.invocation_order) == 1
  end

  test "opens the truthful agent configuration flow" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("g"))
    assert Breeze.Test.render!(session) =~ "Choose an agent"

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
      assert Breeze.Test.render!(session) =~ "Choose an agent"

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
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "DEEPSEEK_API_KEY"
  end

  test "never exposes room navigation at any terminal width" do
    medium = start_session({120, 32})
    wide = start_session({160, 32})
    on_exit(fn -> Breeze.Test.stop(medium) end)
    on_exit(fn -> Breeze.Test.stop(wide) end)

    for session <- [medium, wide] do
      screen = Breeze.Test.render!(session)
      assert screen =~ "Welcome to ReyCode"
      refute screen =~ "ROOMS"
      refute screen =~ "Ctrl+N new"
      refute screen =~ "# reycode"
    end
  end

  test "cycles focus directly between the prompt and current session" do
    session = start_session({160, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)
    baseline_sequence = ReyCode.snapshot().sequence

    type(session, "Focus this session")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders?(session, "Focus this session", baseline_sequence)

    session_id = Breeze.Test.metadata(session).assigns.selected_room_id
    timeline_id = State.timeline_id(session_id)
    assert {:noreply, ^timeline_id, true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Tab")
  end

  test "exposes only session-level global shortcuts" do
    keys = Enum.map(ReyCode.TUI.global_keybindings(), &elem(&1, 0))

    assert keys == ["Tab", "^N", "^P", "^S", "^G", "^T", "^Q"]
    refute Enum.any?(keys, &(&1 in ["^O", "^R"]))
  end

  test "wraps long responses without transcript rails or excess turn spacing" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    session_id = Breeze.Test.metadata(session).assigns.selected_room_id
    push_projection(session, long_response_projection(session_id))

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    assert Breeze.Test.render!(session) =~ "Resume a session"
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = session |> Breeze.Test.render!() |> plain()
    lines = String.split(screen, "\n")
    user_line = Enum.find_index(lines, &String.contains?(&1, "You  ·"))
    assistant_line = Enum.find_index(lines, &String.contains?(&1, "Assistant  ·"))

    assert Enum.all?(lines, &(String.length(&1) <= 120))
    assert Enum.count(lines, &String.contains?(&1, "responses must wrap")) >= 3
    refute Enum.any?(lines, &String.contains?(&1, "│ You"))
    assert assistant_line - user_line <= 2

    assert screen =~ "12.4k/200k"
    assert screen =~ "⑂"
    assert screen =~ "thinking"
    assert screen =~ ~r/\d+s/

    assert screen =~ "Tool · read"
    assert screen =~ "hello.txt"
    assert screen =~ "ok"
  end

  test "renders nested provider usage totals" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    session_id = Breeze.Test.metadata(session).assigns.selected_room_id

    projection =
      long_response_projection(session_id)
      |> put_in(
        [:invocations, "inv-layout", :usage],
        %{
          "tokens" => %{
            "cache" => %{"read" => 0, "write" => 0},
            "input" => 16_539,
            "output" => 8,
            "reasoning" => 47,
            "total" => 16_594
          }
        }
      )

    assert %{sequence: _applied} = push_projection(session, projection)
    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert plain(Breeze.Test.render!(session)) =~ "16.6k/200k"

    split_projection =
      put_in(
        projection,
        [:invocations, "inv-layout", :usage],
        %{"tokens" => %{"input" => 100, "output" => 5}}
      )

    assert %{sequence: _split} = push_projection(session, split_projection)

    assert plain(Breeze.Test.render!(session)) =~ "105/200k"

    total_projection =
      put_in(split_projection, [:invocations, "inv-layout", :usage], %{"total_tokens" => 42})

    assert %{sequence: _total} = push_projection(session, total_projection)

    assert plain(Breeze.Test.render!(session)) =~ "42/200k"
  end

  test "@path attaches file content into the posted message body" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    baseline = Engine.snapshot(engine).sequence
    type(session, "read @README.md")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))

    assert Wait.projection(engine, &projection_with_message(&1, "README.md:", baseline), 3_000)

    projection = Engine.snapshot(engine)

    assert Enum.any?(projection.messages, fn {_id, m} ->
             String.contains?(m.body, "README.md:")
           end)

    assert Enum.any?(projection.messages, fn {_id, m} ->
             String.contains?(m.body, "ReyCode is a terminal-native coding harness")
           end)
  end

  test "hides prior transcript history until the user explicitly resumes" do
    %{engine: engine, room_id: session_id} = start_isolated_stack([])

    assert {:ok, turn_id} =
             Engine.post_message(session_id, "Previous session message", :direct, engine)

    assert Wait.terminal_turn(engine, turn_id).outcome == :completed

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    refute Breeze.Test.render!(session) =~ "Previous session message"

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    picker_screen = session |> Breeze.Test.render!() |> plain()
    assert picker_screen =~ "Resume a session"
    assert picker_screen =~ "ReyCode"
    assert picker_screen =~ "just now"
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    resumed = Breeze.Test.render!(session)
    assert resumed =~ "Previous session message"
    refute resumed =~ "#"
  end

  test "Ctrl+P opens commands and Escape restores the existing draft" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)
    session_id = Breeze.Test.metadata(session).assigns.selected_room_id

    type(session, "Keep this draft")

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("p"))
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.modal == :slash
    assert metadata.assigns.slash.query == "/"
    assert metadata.assigns.drafts[session_id] == "/"

    screen = Breeze.Test.render!(session)
    assert screen =~ "/agents"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "Keep this draft"
    assert Breeze.Test.render!(session) =~ "Keep this draft"
  end

  test "an unknown slash command is never posted to the session" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/bogus")

    assert Breeze.Test.render!(session) =~ "No matching commands"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Unknown command"
    refute screen =~ "No matching commands"
    session_id = Breeze.Test.metadata(session).assigns.selected_room_id
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == ""
  end

  test "runs a slash command with the prompt shortcut" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/theme")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    refute screen =~ "ReyCode commands"
  end

  test "opens the deterministic capability help modal" do
    session = start_session({120, 32})
    on_exit(fn -> Breeze.Test.stop(session) end)

    providers = %{
      configured: %{name: "Configured", status: :configured, models: ["model"]},
      available: %{name: "Available", status: :available, models: []},
      checking: %{name: "Checking", status: :checking, models: []},
      missing: %{name: "Missing", status: :missing, models: []},
      unchecked: %{name: "Unchecked", status: :unchecked, models: []},
      error: %{name: "Error", status: :error, models: []},
      binary: %{name: "Binary", status: "ready", models: []},
      unknown: %{name: "Unknown", status: :other, models: []}
    }

    assert {:noreply, _focused} = push_providers(session, providers)

    type(session, "/help")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")

    screen = Breeze.Test.render!(session) |> plain()
    assert screen =~ "What ReyCode can do"
    assert screen =~ "Durable conversations scoped to one workspace"
    assert screen =~ "Providers now"
    assert screen =~ "OMP"
    assert screen =~ "Type / for commands"
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
    task_supervisor = :"tui_tasks_#{suffix}"
    start_supervised!({Registry, keys: :unique, name: agent_registry})

    start_supervised!({Registry, keys: :duplicate, name: event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_supervisor})
    start_supervised!({Task.Supervisor, name: task_supervisor})
    config = configured_runtime(config_overrides)

    engine = :"tui_engine_#{suffix}"

    opts = [
      name: engine,
      event_store: store,
      agent_supervisor: agent_supervisor,
      agent_registry: agent_registry,
      event_registry: event_registry,
      task_supervisor: task_supervisor,
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

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  # Synthetic fixtures must respect the monotonic subscription contracts:
  # each push advances the version the session currently holds.
  defp push_projection(session, projection) do
    next_sequence = Breeze.Test.metadata(session).assigns.projection.sequence + 1
    projection = Map.put(projection, :sequence, next_sequence)

    assert {:noreply, _focused} = Breeze.Test.info(session, {:projection_snapshot, projection})
    projection
  end

  defp push_providers(session, providers) do
    generation = Breeze.Test.metadata(session).assigns.providers_generation + 1

    snapshot = %ReyCode.Provider.Catalog.Snapshot{generation: generation, providers: providers}

    assert {:noreply, _focused} = Breeze.Test.info(session, {:provider_catalog_updated, snapshot})
  end

  defp long_response_projection(session_id) do
    projection = ReyCode.snapshot()
    room = projection.rooms[session_id]
    turn_id = "turn-layout"
    invocation_id = "inv-layout"
    user_message_id = "msg-layout-user"
    assistant_message_id = "msg-layout-assistant"

    user = %{
      id: user_message_id,
      room_id: session_id,
      turn_id: turn_id,
      invocation_id: nil,
      author: %{kind: :user, id: "user", name: "You"},
      role: :user,
      status: :completed,
      body: "Explain the layout",
      created_at: "2026-08-24T20:00:00Z",
      created_sequence: projection.sequence,
      error: nil
    }

    assistant = %{
      id: assistant_message_id,
      room_id: session_id,
      turn_id: turn_id,
      invocation_id: invocation_id,
      author: %{kind: :agent, id: "assistant", name: "Assistant"},
      role: :assistant,
      status: :completed,
      body:
        Enum.map_join(1..10, " ", fn _index ->
          "Long responses must wrap cleanly within the available transcript width."
        end),
      created_at: "2026-08-24T20:00:01Z",
      created_sequence: projection.sequence,
      error: nil
    }

    invocation = %{
      id: invocation_id,
      participant: %{
        id: "assistant",
        name: "Assistant",
        provider: :opencode,
        model: "openai/gpt-5.4-mini"
      },
      room_id: session_id,
      turn_id: turn_id,
      usage: %{"prompt_tokens" => 12_000, "completion_tokens" => 400},
      pending_tool_review: nil,
      tool_runs: %{
        "run-1" => %{
          tool: :read,
          arguments: %{"path" => "/tmp/hello.txt"},
          status: :completed,
          result: %{
            "ok" => true,
            "output" => "hello world\n",
            "error" => nil,
            "truncated" => false,
            "metadata" => %{}
          }
        }
      },
      tool_run_order: ["run-1"]
    }

    running_turn = %{
      mode: :direct,
      status: :running,
      created_at:
        DateTime.utc_now()
        |> DateTime.add(-5, :second)
        |> DateTime.to_iso8601()
    }

    projection
    |> put_in([:rooms, session_id], %{
      room
      | message_order: [assistant_message_id, user_message_id],
        active_turn_id: turn_id,
        workspace: File.cwd!()
    })
    |> put_in([:messages, user_message_id], user)
    |> put_in([:messages, assistant_message_id], assistant)
    |> put_in([:turns, turn_id], running_turn)
    |> put_in([:invocations, invocation_id], invocation)
  end

  defp ctrl(key), do: %{"ctrlKey" => true, "key" => key}

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

  defp eventually_renders_on?(session, engine, text, baseline_sequence, attempts \\ 300) do
    projection =
      Wait.projection(
        engine,
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
