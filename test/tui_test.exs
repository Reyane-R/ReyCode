defmodule ReyCode.TUITest do
  use ExUnit.Case, async: true

  alias ReyCode.{ArtifactStore, EventStore, RuntimeConfig}
  alias ReyCode.Memory.Store

  alias ReyCode.Orchestration.{
    Author,
    Engine,
    Invocation,
    InvocationCoordination,
    InvocationExecution,
    Message,
    OperatorQuestion,
    Participant,
    PeerMessage,
    Session,
    ToolAsk,
    Turn,
    WorkPlan
  }

  alias ReyCode.Orchestration.OperatorQuestion.Item
  alias ReyCode.Security.CanonicalPath

  alias ReyCode.Test.Wait
  alias ReyCode.Tool.Result
  alias ReyCode.TUI.{AnimationClock, Notice, State}

  defmodule RecordingTerminal do
    def write(owner, _data), do: {:ok, owner}
    def resize(_owner), do: %{width: 120, height: 32}
  end

  test "terminal redraws coalesce projection bursts and preserve keyboard navigation" do
    %{engine: engine} = start_isolated_stack([])
    reader = make_ref()

    terminal = %Termite.Terminal{
      reader: reader,
      adapter: {RecordingTerminal, self()},
      size: %{width: 120, height: 32}
    }

    {:ok, server} =
      Breeze.Server.start_app_link(
        view: ReyCode.TUI,
        terminal: terminal,
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings(),
        start_opts: [engine: engine]
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    view_pid = :sys.get_state(server).view_pid
    session = %Breeze.Test{pid: view_pid, terminal: terminal}
    baseline = GenServer.call(server, :stats).render_base_count
    :ok = :sys.suspend(server)
    projection = Engine.snapshot(engine)
    for _index <- 1..20, do: push_projection(session, projection)
    :ok = :sys.resume(server)
    state = :sys.get_state(server)

    if state.input.render_timer_token,
      do: send(server, {:flush_input_render, state.input.render_timer_token})

    stats = GenServer.call(server, :stats)
    assert stats.render_base_count - baseline <= 2

    Breeze.Test.event(session, "prompt_changed", %{value: "/", cursor: 1})
    Breeze.Test.render!(session)
    send(server, {reader, {:data, "\e[B"}})
    send(server, {reader, {:data, "\e[B"}})
    send(server, {reader, {:data, "\e[B"}})
    assert_navigation_settled(session, server, 100)
    assert Breeze.Test.metadata(session).assigns.slash.index == 3
  end

  defp assert_navigation_settled(_session, _server, 0), do: flunk("input did not settle")

  defp assert_navigation_settled(session, server, attempts) do
    state = :sys.get_state(server)

    if state.input.pending_ref || not :queue.is_empty(state.input.queued_input) do
      assert_navigation_settled(session, server, attempts - 1)
    else
      :ok
    end
  end

  test "starts clean and creates a fresh durable session for the first message" do
    %{engine: tui_engine_1} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_1)
    on_exit(fn -> Breeze.Test.stop(session) end)

    source_session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    screen = Breeze.Test.render!(session)
    assert screen =~ "REYCODE"
    assert screen =~ "AI workbench"
    assert screen =~ "Assistant"
    assert screen =~ "Quick start"
    assert screen =~ "Workspace"
    assert screen =~ "Browse actions"
    assert screen =~ "Message Assistant"
    assert screen =~ "commands"
    refute screen =~ "You ·"
    refute screen =~ "# reycode"

    engine = Breeze.Test.metadata(session).assigns.engine
    baseline_sequence = Engine.snapshot(engine).sequence

    type(session, "Handle this directly")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders?(session, "Handle this directly", baseline_sequence)

    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.selected_session_id != source_session_id

    session_room = Engine.snapshot(engine).sessions[metadata.assigns.selected_session_id]
    assert session_room.title == "Handle this directly"
    session_screen = Breeze.Test.render!(session)
    assert session_screen =~ "ReyCode"
    assert session_screen =~ "Handle this directly"
    refute session_screen =~ "#"
  end

  test "startup selects the newest Session rooted at the launch Workspace" do
    workspace = temporary_workspace("launch")
    foreign_workspace = temporary_workspace("foreign")

    %{engine: engine} =
      start_isolated_stack(workspace_roots: [workspace, foreign_workspace])

    assert {:ok, _older_id} = Engine.create_blank_session("Older local", workspace, engine)
    assert {:ok, local_id} = Engine.create_blank_session("Newest local", workspace, engine)

    assert {:ok, foreign_id} =
             Engine.create_blank_session("Global latest", foreign_workspace, engine)

    assert List.last(Engine.snapshot(engine).session_order) == foreign_id

    session = start_session({120, 32}, engine: engine, workspace: workspace)
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert Breeze.Test.metadata(session).assigns.selected_session_id == local_id
  end

  test "startup creates one reusable blank source Session for a new launch Workspace" do
    workspace = temporary_workspace("new")
    %{engine: engine} = start_isolated_stack(workspace_roots: [workspace])

    missing_workspace = Path.join(workspace, "missing")

    assert Engine.ensure_workspace_session(missing_workspace, engine) ==
             {:error, :invalid_workspace}

    assert Engine.create_blank_session("Invalid", missing_workspace, engine) ==
             {:error, :invalid_workspace}

    first = start_session({120, 32}, engine: engine, workspace: workspace)
    first_id = Breeze.Test.metadata(first).assigns.selected_session_id
    assert Engine.snapshot(engine).sessions[first_id].workspace == workspace
    assert workspace_session_ids(engine, workspace) == [first_id]
    Breeze.Test.stop(first)

    second = start_session({120, 32}, engine: engine, workspace: workspace)
    on_exit(fn -> Breeze.Test.stop(second) end)

    assert Breeze.Test.metadata(second).assigns.selected_session_id == first_id
    assert workspace_session_ids(engine, workspace) == [first_id]
  end

  test "composer supports multiline drafts without submitting" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "first line")

    assert {:noreply, "prompt", _changed?} =
             Breeze.Test.input(session, %{"shiftKey" => true, "key" => "Enter"})

    type(session, "second line")

    assert Breeze.Test.metadata(session).assigns.drafts
           |> Map.values()
           |> Enum.member?("first line\nsecond line")

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowUp")

    assert Enum.member?(
             Map.values(Breeze.Test.metadata(session).assigns.drafts),
             "first line\nsecond line"
           )
  end

  test "up and down recall prompts while preserving the current scratch draft" do
    %{engine: engine, session_id: session_id} = start_isolated_stack([])
    assert {:ok, turn_id} = Engine.post_message(session_id, "previous prompt", :direct, engine)
    assert wait_until_turn_status(engine, turn_id, :completed)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)
    type(session, "scratch")

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "previous prompt"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "scratch"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "previous prompt"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "scratch"
  end

  test "mouse wheel scrolls the transcript without recalling prompt history" do
    %{engine: engine, session_id: session_id} = start_isolated_stack([])

    session = start_session({120, 24}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    body = Enum.map_join(1..80, "\n", &"- transcript line #{&1}")

    projection =
      long_response_projection(session)
      |> put_in([:messages, "msg-layout-assistant", :body], body)

    push_projection(session, projection)
    open_first_session(session)

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "transcript line 78"
    refute screen =~ "• transcript line 1 "

    wheel_up = %{
      "mouse" => %{
        "button" => "wheel_up",
        "action" => "press",
        "repeat" => 10,
        "x" => 10,
        "y" => 10
      }
    }

    draft_before = Breeze.Test.metadata(session).assigns.drafts[session_id]
    assert {:noreply, _focused, true} = Breeze.Test.input(session, wheel_up)

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "transcript line 1"
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == draft_before
  end

  test "fuzzy file mention completion inserts the selected workspace path" do
    workspace =
      Path.join(System.tmp_dir!(), "rey-code-tui-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/fuzzy_target.ex"), "value = 1\n")
    File.write!(Path.join(workspace, "lib/my spaced file.ex"), "value = 2\n")
    File.mkdir_p!(Path.join(workspace, "sealed"))
    File.chmod!(Path.join(workspace, "sealed"), 0)

    :ok =
      :file.make_symlink(
        to_charlist("elsewhere"),
        to_charlist(Path.join(workspace, "dangling"))
      )

    on_exit(fn ->
      File.chmod!(Path.join(workspace, "sealed"), 0o755)
      File.rm_rf!(workspace)
    end)

    %{engine: engine} = start_isolated_stack(workspace_roots: [workspace])
    assert {:ok, session_id} = Engine.create_blank_session("File completion", workspace, engine)

    session = start_session({120, 32}, engine: engine, workspace: workspace)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "Read @fzt")
    assert Breeze.Test.metadata(session).assigns.modal == :slash
    assert Breeze.Test.render!(session) =~ "@lib/fuzzy_target.ex"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Tab")
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.modal == nil
    assert metadata.assigns.drafts[session_id] == "Read @lib/fuzzy_target.ex "

    type(session, " Fix @my")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Tab")

    assert Breeze.Test.metadata(session).assigns.drafts[session_id] ==
             "Read @lib/fuzzy_target.ex  Fix @\"lib/my spaced file.ex\" "
  end

  test "/new starts another clean durable session" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    first_baseline = Engine.snapshot(engine).sequence
    type(session, "First session message")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders_on?(session, engine, "First session message", first_baseline)
    first_session_id = Breeze.Test.metadata(session).assigns.selected_session_id

    type(session, "/new")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "AI workbench"

    second_baseline = Engine.snapshot(engine).sequence
    type(session, "Second session message")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders_on?(session, engine, "Second session message", second_baseline)

    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.selected_session_id != first_session_id

    screen = Breeze.Test.render!(session)
    assert screen =~ "Second session message"
    refute screen =~ "First session message"
  end

  test "! runs an owner shell command into a new session transcript" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    baseline = Engine.snapshot(engine).sequence
    type(session, "!echo tier-one-owner")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    assert eventually_renders_on?(session, engine, "tier-one-owner", baseline)

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    session_record = Engine.snapshot(engine).sessions[session_id]
    assert session_record.title == "echo tier-one-owner"

    assert Enum.any?(session_record.message_order, fn id ->
             String.contains?(Engine.snapshot(engine).messages[id].body, "! echo tier-one-owner")
           end)
  end

  test "Escape cancels the running turn" do
    %{engine: engine, session_id: session_id} = start_isolated_stack(agent_delay_ms: 5_000)

    assert {:ok, turn_id} = Engine.post_message(session_id, "Escape me", :direct, engine)
    assert wait_until_turn_status(engine, turn_id, :running)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("r"))
    assert Breeze.Test.render!(session) =~ "Prompt history"
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")
    assert wait_until_turn_status(engine, turn_id, :cancelled)
    assert Breeze.Test.render!(session) =~ "Task cancelled"
  end

  test "/model switches the Assistant model from the catalog in one step" do
    %{engine: engine} = start_isolated_stack([])
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

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id

    primary =
      Enum.find(Engine.snapshot(engine).sessions[session_id].participants, &(&1.kind == :primary))

    assert primary.provider == :simulator
  end

  test "/model rejects when no provider is configured" do
    %{engine: tui_engine_2} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_2)
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, _focused} = push_providers(session, %{})

    type(session, "/model")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "No providers configured"
  end

  test "shows the untruncated workspace from the command palette" do
    %{engine: tui_engine_3} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_3)
    on_exit(fn -> Breeze.Test.stop(session) end)
    metadata = Breeze.Test.metadata(session)

    expected_workspace =
      metadata.assigns.projection.sessions[metadata.assigns.selected_session_id].workspace

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
    %{engine: engine, session_id: session_id} = start_isolated_stack(agent_delay_ms: 5_000)

    assert {:ok, turn_id} =
             Engine.post_message(session_id, "Cancel this owner run", :compare, engine)

    assert wait_until_turn_status(engine, turn_id, :running)

    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/cancel")
    assert Breeze.Test.render!(session) =~ "Stop current work"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :cancel
    assert Breeze.Test.render!(session) =~ "Cancel current task"
    assert Breeze.Test.render!(session) =~ turn_id

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert wait_until_turn_status(engine, turn_id, :cancelled)
    assert Breeze.Test.render!(session) =~ "Task cancelled"
  end

  test "keeps the session home and command palette usable in a narrow terminal" do
    %{engine: tui_engine_4} = start_isolated_stack([])
    session = start_session({50, 20}, engine: tui_engine_4)
    on_exit(fn -> Breeze.Test.stop(session) end)

    screen = Breeze.Test.render!(session)
    assert screen =~ "AI workbench"
    assert screen =~ "Message Assistant"

    type(session, "/")
    palette_screen = Breeze.Test.render!(session)
    assert palette_screen =~ "Work with task agents"
    assert palette_screen =~ "Settings…"
    refute palette_screen =~ "/workspace"
    refute palette_screen =~ "/advise"

    type(session, "workspace")
    searched_screen = Breeze.Test.render!(session)
    assert searched_screen =~ "/workspace"
    refute searched_screen =~ "/task"
  end

  test "/model keeps long model candidates on one row in a wide terminal" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    providers = %{
      ollama: %{
        id: :ollama,
        name: "Ollama",
        status: :configured,
        models: ["openai-codex/gpt-5.4-mini"]
      }
    }

    assert {:noreply, _focused} = push_providers(session, providers)

    type(session, "/model")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Tab")
    screen = session |> Breeze.Test.render!() |> plain()

    assert screen =~ "ollama/openai-codex/gpt-5.4-mini"
  end

  test "model filter treats terminal DEL as Backspace in the rendered TUI" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    providers = %{
      ollama: %{
        id: :ollama,
        name: "Ollama",
        status: :configured,
        models: ["ollama/alpha", "ollama/alpine"]
      }
    }

    assert {:noreply, _focused} = push_providers(session, providers)

    type(session, "/connect")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.settings.step == :participants

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.settings.step == :providers

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.settings.step == :models

    type(session, "alph")
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Filter: alph  (type to search"
    assert screen =~ "ollama/alpha"
    refute screen =~ "ollama/alpine"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "\x7F")
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Filter: alp  (type to search"
    assert screen =~ "ollama/alpha"
    assert screen =~ "ollama/alpine"
  end

  test "model selection failure stays visible in a short terminal" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({100, 20}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    models = Enum.map(1..12, &"ollama/model-#{&1}")

    providers = %{
      ollama: %{id: :ollama, name: "Ollama", status: :configured, models: models}
    }

    assert {:noreply, _focused} = push_providers(session, providers)

    type(session, "/connect")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.settings.step == :participants

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.settings.step == :providers

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.settings.step == :models

    # The pushed catalog exists only in the TUI assigns, so the Engine
    # rejects the selection and the wizard must explain why on screen.
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :settings

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Could not configure agents"
    assert screen =~ "Arrow keys or j/k move"
  end

  test "opens guided Primary provider and model setup on first run" do
    %{engine: engine, config: config} =
      start_isolated_stack(default_provider: :unconfigured)

    session = start_session({120, 32}, engine: engine, config: config)
    on_exit(fn -> Breeze.Test.stop(session) end)

    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.modal == :settings
    assert metadata.assigns.settings.step == :providers
    assert metadata.assigns.settings.participant_ids == ["assistant"]
    assert metadata.assigns.settings.onboarding?

    screen = Breeze.Test.render!(session)
    assert screen =~ "Set up your Assistant"
    assert screen =~ "Choose a provider runtime, then select the model"

    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.modal == nil
  end

  test "/connect opens provider settings without model completion" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/connect")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.modal == :settings
    assert metadata.assigns.settings.step == :participants
    assert Breeze.Test.render!(session) =~ "Configure agents"
  end

  test "creates a task agent before selecting its provider and model" do
    %{engine: engine, session_id: session_id} = start_isolated_stack([])
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
      Engine.snapshot(engine).sessions[session_id].participants
      |> Enum.find(&(&1.id == participant_id))

    assert participant.name == "Release"
    assert participant.perspective == "Commit, push, and deploy approved changes"
    assert participant.kind == :task
  end

  test "delegates one task to one configured task agent" do
    %{engine: engine, session_id: session_id} = start_isolated_stack([])

    assert {:ok, participant_id} =
             Engine.add_task_participant(
               session_id,
               "Tests",
               "Run the relevant tests and report failures",
               engine
             )

    assert :ok =
             Engine.configure_participants(session_id, participant_id, :simulator, nil, engine)

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
    %{engine: tui_engine_5} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_5)
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("g"))
    assert Breeze.Test.render!(session) =~ "Choose an agent"

    assert {:noreply, _focused, true} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Select a runtime"
    refute screen =~ "OpenCode"
    assert screen =~ "DeepSeek"
    refute screen =~ "Demo"
    assert screen =~ "Provider discovery is disabled"
  end

  test "keeps the settings flow usable at narrow and wide terminal sizes" do
    %{engine: tui_engine_6} = start_isolated_stack([])
    narrow = start_session({50, 20}, engine: tui_engine_6)
    wide = start_session({160, 32}, engine: tui_engine_6)
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
    %{engine: tui_engine_7} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_7)
    on_exit(fn -> Breeze.Test.stop(session) end)

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("g"))
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")

    screen = Breeze.Test.render!(session)
    assert screen =~ "Select a runtime"
    refute screen =~ "OpenCode"
    assert screen =~ "DeepSeek"
    refute screen =~ "OMP"

    assert Breeze.Test.render!(session) =~ "Provider discovery is disabled"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "DEEPSEEK_API_KEY"
  end

  test "never exposes room navigation at any terminal width" do
    %{engine: tui_engine_8} = start_isolated_stack([])
    medium = start_session({120, 32}, engine: tui_engine_8)
    wide = start_session({160, 32}, engine: tui_engine_8)
    on_exit(fn -> Breeze.Test.stop(medium) end)
    on_exit(fn -> Breeze.Test.stop(wide) end)

    for session <- [medium, wide] do
      screen = Breeze.Test.render!(session)
      assert screen =~ "AI workbench"
      refute screen =~ "ROOMS"
      refute screen =~ "Ctrl+N new"
      refute screen =~ "# reycode"
    end
  end

  test "cycles focus through the session and its model settings action" do
    %{engine: tui_engine_9} = start_isolated_stack([])
    session = start_session({160, 32}, engine: tui_engine_9)
    on_exit(fn -> Breeze.Test.stop(session) end)

    engine = Breeze.Test.metadata(session).assigns.engine
    baseline_sequence = Engine.snapshot(engine).sequence

    type(session, "Focus this session")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("s"))
    assert eventually_renders?(session, "Focus this session", baseline_sequence)

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    timeline_id = State.timeline_id(session_id)
    assert {:noreply, ^timeline_id, true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "choose-model", true} = Breeze.Test.input(session, "Tab")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Tab")
    Breeze.Test.input(session, "Tab")
    Breeze.Test.input(session, "Tab")
    Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :settings
    assert Breeze.Test.render!(session) =~ "Configure agents"
  end

  test "startup announces newer published releases with the update command" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    notice = "Update available: 0.1.0 → v9.9.9 · run `reycode update`"
    assert {:noreply, _focused} = Breeze.Test.info(session, {:update_available, notice})

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ notice

    assert %Notice{severity: :info, message: ^notice} =
             Breeze.Test.metadata(session).assigns.update_notice
  end

  test "exposes only session-level global shortcuts" do
    keys = Enum.map(ReyCode.TUI.global_keybindings(), &elem(&1, 0))

    assert keys == [
             "Tab",
             "^N",
             "^P",
             "^S",
             "^A",
             "^B",
             "^O",
             "^R",
             "ArrowUp",
             "ArrowDown",
             "^G",
             "^T",
             "^Q"
           ]

    assert Enum.uniq(keys) == keys
  end

  test "wraps long responses with quiet hierarchy and bounded turn spacing" do
    %{engine: tui_engine_10} = start_isolated_stack([])
    session = start_session({120, 44}, engine: tui_engine_10)
    on_exit(fn -> Breeze.Test.stop(session) end)

    push_projection(session, long_response_projection(session))

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    assert Breeze.Test.render!(session) =~ "Resume a session"
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = session |> Breeze.Test.render!() |> plain()
    lines = String.split(screen, "\n")
    user_line = Enum.find_index(lines, &String.contains?(&1, "╱ You"))
    assistant_line = Enum.find_index(lines, &String.contains?(&1, "Assistant ·"))

    assert Enum.all?(lines, &(String.length(&1) <= 120))
    assert Enum.count(lines, &String.contains?(&1, "responses must wrap")) >= 3
    refute Enum.any?(lines, &String.contains?(&1, "│ You"))
    assert assistant_line - user_line <= 2

    assert screen =~ "reported 12.4k tok"
    assert screen =~ "⑂"
    assert screen =~ "Thinking"
    assert screen =~ ~r/\d+s/

    refute screen =~ "TOOL /"
    assert screen =~ ~r/Read\s+<outside workspace>/
    assert screen =~ "@@ patch 1 @@"
    assert screen =~ "-hello"
    assert screen =~ "+hello world"
    assert screen =~ "no-change line"

    assert screen =~ "✓"
  end

  test "renders Mermaid message fences as bounded ASCII in the timeline" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    diagram = """
    ```mermaid
    flowchart TD
      A[Inspect] --> B[Implement]
    ```
    """

    projection =
      session
      |> long_response_projection()
      |> put_in([:messages, "msg-layout-assistant", :body], diagram)

    push_projection(session, projection)
    open_first_session(session)
    screen = session |> Breeze.Test.render!() |> plain()

    assert screen =~ "Diagram · flowchart"
    assert screen =~ "Inspect ──▶ Implement"
  end

  test "Session Cartography navigates forks, ToolRuns, context, and prompt history" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = long_response_projection(session)
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    %Session{} = source = projection.sessions[session_id]

    fork = %Session{
      source
      | id: "session-fork",
        title: "Layout experiment",
        parent_session_id: session_id,
        forked_from_sequence: max(projection.sequence, 1),
        message_order: [],
        active_turn_id: nil
    }

    projection =
      projection
      |> put_in([:sessions, session_id], %{
        source
        | context_boundary_sequence: max(projection.sequence, 1),
          context_summary: "The layout discussion was compacted for the provider.",
          context_compacted_at: "2026-08-28T00:00:00Z"
      })
      |> put_in([:sessions, fork.id], fork)
      |> Map.update!(:session_order, &(&1 ++ [fork.id]))

    push_projection(session, projection)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("b"))
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    tree_screen = Breeze.Test.render!(session)
    assert tree_screen =~ "Session Tree"
    assert tree_screen =~ "Layout experiment"
    assert tree_screen =~ "Forked from"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    prepared = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()
    assert Enum.any?(prepared.messages, &(&1.kind == :context_boundary))

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("o"))
    runs_screen = Breeze.Test.render!(session)
    assert runs_screen =~ "ToolRun Inspector"
    assert runs_screen =~ "read · completed · Assistant"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    run_screen = Breeze.Test.render!(session)
    assert run_screen =~ "Arguments"
    assert run_screen =~ "hello world"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")
    type(session, "/runs")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "ToolRun Inspector"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")

    type(session, "/context")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    context_screen = Breeze.Test.render!(session)
    assert context_screen =~ "ContextBoundary"
    assert context_screen =~ "layout discussion was compacted"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")

    type(session, "/history")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Prompt history"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")

    type(session, "/hotkeys")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    hotkeys_screen = Breeze.Test.render!(session)
    assert hotkeys_screen =~ "Effective action bindings"
    assert hotkeys_screen =~ "app.session.tree"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, ctrl("r"))

    assert Breeze.Test.render!(session) =~ "Prompt history"
    type(session, "layout")
    assert Breeze.Test.render!(session) =~ "Explain the layout"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "Explain the layout"
  end

  test "decisions browser exposes rationale and invalidation from ProjectMemory" do
    %{engine: engine, session_id: session_id} = start_isolated_stack([])
    workspace = Engine.snapshot(engine).sessions[session_id].workspace

    memory_path =
      Path.join(System.tmp_dir!(), "tui-decisions-#{System.unique_integer([:positive])}.sqlite3")

    memory_store = start_supervised!({Store, name: nil, path: memory_path})
    on_exit(fn -> File.rm(memory_path) end)
    key = "decision-tui-#{System.unique_integer([:positive])}"

    value =
      Jason.encode!(%{
        "statement" => "Use the existing EventStore",
        "rationale" => "It preserves single-writer ordering",
        "alternatives" => "Add PostgreSQL",
        "evidence" => "lib/rey_code/event_store.ex"
      })

    assert {:ok, _memory} =
             Store.record(workspace, "decision", key, value, ["decision"], memory_store)

    session = start_session({120, 32}, engine: engine, memory_store: memory_store)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/decisions")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Decisions & assumptions"
    assert screen =~ key

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    detail = Breeze.Test.render!(session)
    assert detail =~ "Use the existing EventStore"
    assert detail =~ "It preserves single-writer ordering"
    assert detail =~ "lib/rey_code/event_store.ex"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Y")
    assert Breeze.Test.render!(session) =~ "Invalidated #{key}"
    assert {:ok, memories} = Store.list(workspace, ["decision"], 100, memory_store)
    memory = Enum.find(memories, &(&1.key == key))
    refute memory.active
  end

  test "renders a bounded thinking trace before the response" do
    %{engine: tui_engine_12} = start_isolated_stack([])
    session = start_session({120, 80}, engine: tui_engine_12)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection =
      long_response_projection(session)
      |> put_in(
        [:invocations, "inv-layout", :notes],
        Enum.map(1..10, &"reasoning step #{&1}")
      )

    assert %{sequence: _applied} = push_projection(session, projection)

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "+2 earlier thoughts"
    assert screen =~ "┆ reasoning step 3"
    assert screen =~ "┆ reasoning step 10"
    refute Regex.match?(~r/reasoning step 1\s/, screen)

    assert :binary.match(screen, "reasoning step 10") < :binary.match(screen, "Long responses")

    projection =
      put_in(
        projection,
        [:invocations, "inv-layout", :notes],
        [Enum.map_join(1..101, "\n", &"thought line #{&1}")]
      )

    push_projection(session, projection)
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "+93 earlier thoughts"

    activity_events =
      Enum.map(10..1//-1, fn sequence ->
        %{
          "kind" => "agent_note",
          "frame_sequence" => sequence,
          "note" => "native thought #{sequence}"
        }
      end) ++ [%{"kind" => "activity_overflow", "hidden_note_row_count" => 283}]

    projection =
      put_in(
        projection,
        [:invocations, "inv-layout", :provider_activity_events],
        activity_events
      )

    push_projection(session, projection)
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "+285 earlier thoughts"
  end

  test "renders one native provider step alongside the persistent work pulse" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 80}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    started = %{
      "kind" => "tool_started",
      "tool" => "bash",
      "frame_sequence" => 1,
      "state" => %{
        "tool_call_id" => "native-1",
        "status" => "running",
        "arguments" => %{"command" => "mix test"}
      }
    }

    projection =
      long_response_projection(session)
      |> put_in([:invocations, "inv-layout", :provider_activity_events], [started])
      |> put_in([:invocations, "inv-layout", :tool_runs], %{})
      |> put_in([:invocations, "inv-layout", :tool_run_order], [])

    push_projection(session, projection)
    open_first_session(session)

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Running · mix test"
    assert screen =~ ~r/Running\s{2,}mix test/
  end

  test "renders native thoughts and tool steps in provider frame order" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 80}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    note_before = %{
      "kind" => "agent_note",
      "frame_sequence" => 1,
      "note" => "Inspect the project"
    }

    started = %{
      "kind" => "tool_started",
      "tool" => "read",
      "frame_sequence" => 2,
      "state" => %{
        "tool_call_id" => "native-1",
        "status" => "running",
        "arguments" => %{"path" => "mix.exs"}
      }
    }

    completed = %{
      "kind" => "tool_completed",
      "tool" => "read",
      "frame_sequence" => 3,
      "state" => %{"tool_call_id" => "native-1", "status" => "completed"}
    }

    note_after = %{
      "kind" => "agent_note",
      "frame_sequence" => 4,
      "note" => "The project uses Mix"
    }

    projection =
      long_response_projection(session)
      |> put_in(
        [:invocations, "inv-layout", :provider_activity_events],
        [note_after, completed, started, note_before]
      )
      |> put_in([:invocations, "inv-layout", :tool_runs], %{})
      |> put_in([:invocations, "inv-layout", :tool_run_order], [])

    push_projection(session, projection)
    open_first_session(session)

    screen = session |> Breeze.Test.render!() |> plain()
    before_index = :binary.match(screen, "Inspect the project")
    tool_index = Regex.run(~r/Read\s+mix\.exs/, screen, return: :index) |> List.first()
    after_index = :binary.match(screen, "The project uses Mix")
    response_index = :binary.match(screen, "Long responses")

    assert before_index < tool_index
    assert tool_index < after_index
    assert after_index < response_index
  end

  test "Z.ai reasoning batches grow one visible thought while working" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 80}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    first = %{
      "kind" => "agent_note",
      "frame_sequence" => 1,
      "segment_sequence" => 1,
      "note" => "Inspect "
    }

    second = %{
      "kind" => "agent_note",
      "frame_sequence" => 2,
      "segment_sequence" => 1,
      "note" => "the project"
    }

    projection =
      long_response_projection(session)
      |> update_in([:invocations, "inv-layout", :participant], &%{&1 | provider: :zai_coding})
      |> put_in([:invocations, "inv-layout", :provider_activity_events], [first])

    push_projection(session, projection)
    open_first_session(session)
    assert session |> Breeze.Test.render!() |> plain() =~ "┆ Inspect"

    projection =
      put_in(projection, [:invocations, "inv-layout", :provider_activity_events], [second, first])

    push_projection(session, projection)
    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "┆ Inspect the project"
    assert length(Regex.scan(~r/┆ Inspect/, screen)) == 1
  end

  test "renders agent-initiated delegation as a delegate tool row" do
    %{engine: tui_engine_13} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_13)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection =
      long_response_projection(session)
      |> put_in([:invocations, "inv-layout", :tool_runs], %{
        "run-spawn" => %{
          tool: :spawn_task,
          arguments: %{"agent" => "Luna", "brief" => "run the focused tests"},
          status: :running,
          result: nil,
          error: nil,
          child_invocation_id: "inv-child"
        }
      })
      |> put_in([:invocations, "inv-layout", :tool_run_order], ["run-spawn"])

    assert %{sequence: _applied} = push_projection(session, projection)

    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = session |> Breeze.Test.render!() |> plain()
    refute screen =~ "TOOL /"
    assert screen =~ "Delegating · Luna"
  end

  test "renders operation-specific active ToolRun labels within a narrow terminal" do
    %{engine: tui_engine_activity_tools} = start_isolated_stack([])
    session = start_session({72, 32}, engine: tui_engine_activity_tools)
    on_exit(fn -> Breeze.Test.stop(session) end)

    workspace = File.cwd!()

    run_order = [
      "read",
      "grep",
      "glob",
      "list",
      "bash",
      "edit",
      "write",
      "memory",
      "memory-done",
      "spawn"
    ]

    runs = %{
      "read" => %{
        id: "read",
        tool: :read,
        arguments: %{"path" => Path.join(workspace, "lib/a.ex")},
        status: :running
      },
      "grep" => %{id: "grep", tool: :grep, arguments: %{"pattern" => "needle"}, status: :running},
      "glob" => %{id: "glob", tool: :glob, arguments: %{"path" => "lib"}, status: :running},
      "list" => %{id: "list", tool: :list, arguments: %{"path" => "test"}, status: :running},
      "bash" => %{
        id: "bash",
        tool: :bash,
        arguments: %{"command" => "mix test\n--trace"},
        status: :running
      },
      "edit" => %{id: "edit", tool: :edit, arguments: %{"path" => "lib/a.ex"}, status: :running},
      "write" => %{
        id: "write",
        tool: :write,
        arguments: %{"path" => "README.md"},
        status: :running
      },
      "memory" => %{
        id: "memory",
        tool: :memory,
        arguments: %{"action" => "retain", "kind" => "decision", "key" => "storage"},
        status: :running
      },
      "memory-done" => %{
        id: "memory-done",
        tool: :memory,
        arguments: %{"action" => "retain", "kind" => "decision", "key" => "decision-log"},
        status: :completed
      },
      "spawn" => %{
        id: "spawn",
        tool: :spawn_task,
        arguments: %{"agent" => "Luna"},
        status: :running,
        child_invocation_id: "child"
      }
    }

    projection =
      long_response_projection(session)
      |> put_in([:messages, "msg-layout-assistant", :status], :streaming)
      |> put_in([:messages, "msg-layout-assistant", :body], "")
      |> put_in([:invocations, "inv-layout", :tool_runs], runs)
      |> put_in([:invocations, "inv-layout", :tool_run_order], run_order)

    push_projection(session, projection)
    open_first_session(session)

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ ~r/Reading\s+lib\/a.ex/
    assert screen =~ ~r/Searching\s+needle/
    assert screen =~ ~r/Scanning\s+lib/
    assert screen =~ ~r/Scanning\s+test/
    assert screen =~ ~r/Running\s+mix test --trace/
    assert screen =~ ~r/Editing\s+lib\/a\.ex/
    assert screen =~ ~r/Writing\s+README\.md/
    assert screen =~ ~r/Delegating\s+Luna/
    assert screen =~ ~r/Recording\s+storage/
    assert screen =~ ~r/Recorded\s+decision-log/
    assert Enum.all?(String.split(screen, "\n"), &(String.length(&1) <= 72))
  end

  test "usage is cumulative and informational even when historical budget metadata is present" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection =
      session
      |> long_response_projection()
      |> put_in(
        [:invocations, "inv-layout", :execution_context],
        %InvocationExecution{model_tier: :standard, token_budget_tokens: 15_000}
      )
      |> put_in([:invocations, "inv-layout", :usage], %{"total_tokens" => 12_400})

    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()

    assert assigns.token_label == "reported 12.4k tok · session"
    refute Map.has_key?(assigns, :budget_notice)
    refute assigns.token_label_class =~ "warning"

    projection =
      put_in(projection, [:invocations, "inv-layout", :rounds], [
        %{usage: %{"total_tokens" => 10_000}},
        %{usage: %{"total_tokens" => 15_000}}
      ])

    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()
    assert assigns.token_label == "reported 25k tok · session"

    projection = put_in(projection, [:invocations, "inv-layout", :status], :completed)
    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()
    assert assigns.token_label == "reported 25k tok · session"
  end

  test "usage label distinguishes cumulative processing from estimated context occupancy" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    metrics = %ReyCode.Orchestration.ProviderRoundAttempt.RequestMetrics{
      prompt_bytes: 129_809,
      max_prompt_bytes: 2_000_000,
      estimated_prompt_tokens: 32_453,
      input_budget_tokens: 183_616
    }

    projection =
      session
      |> long_response_projection()
      |> put_in([:invocations, "inv-layout", :usage], %{"total_tokens" => 336_500})
      |> put_in([:invocations, "inv-layout", :last_request_metrics], metrics)

    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()

    assert assigns.token_label ==
             "reported 336.5k tok · session · ctx ~32.5k/183.6k tok"
  end

  test "usage label exposes a tighter byte ceiling" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    metrics = %ReyCode.Orchestration.ProviderRoundAttempt.RequestMetrics{
      prompt_bytes: 120_000,
      max_prompt_bytes: 128_000,
      estimated_prompt_tokens: 30_000,
      input_budget_tokens: 200_000
    }

    projection =
      session
      |> long_response_projection()
      |> put_in([:invocations, "inv-layout", :last_request_metrics], metrics)

    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()

    assert assigns.token_label =~ "ctx 120k/128k bytes"
  end

  test "usage label does not present older occupancy for a newer unassessed request" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    metrics = %ReyCode.Orchestration.ProviderRoundAttempt.RequestMetrics{
      prompt_bytes: 120_000,
      max_prompt_bytes: 128_000,
      estimated_prompt_tokens: 30_000,
      input_budget_tokens: 200_000
    }

    projection = long_response_projection(session)
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    session_record = projection.sessions[session_id]
    older = projection.invocations["inv-layout"]

    newer_message = %{
      projection.messages[older.message_id]
      | id: "msg-newer",
        created_sequence: 12
    }

    newer =
      Map.merge(older, %{
        id: "inv-newer",
        message_id: newer_message.id,
        usage: nil,
        last_request_metrics: nil,
        last_request_metrics_sequence: nil
      })

    projection =
      projection
      |> put_in([:invocations, "inv-layout", :last_request_metrics], metrics)
      |> put_in([:invocations, "inv-layout", :last_request_metrics_sequence], 11)
      |> put_in([:invocations, newer.id], newer)
      |> put_in([:messages, newer_message.id], newer_message)
      |> put_in(
        [:sessions, session_id],
        %{session_record | message_order: [newer_message.id | session_record.message_order]}
      )

    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()

    refute assigns.token_label =~ "ctx "
  end

  test "plain drag copies transcript text even when release crosses into the composer" do
    %{engine: engine} = start_isolated_stack([])
    owner = self()

    copy = fn text ->
      send(owner, {:selection_copied, text})
      :ok
    end

    session = start_session({120, 32}, engine: engine, selection_copy: copy)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection =
      session
      |> long_response_projection()
      |> put_in([:messages, "msg-layout-assistant", :body], "Hello wide 世界 and friends")

    push_projection(session, projection)
    open_first_session(session)
    Breeze.Test.render!(session)
    layouts = Breeze.ChildServer.layout_snapshot(session.pid).elements
    line = Map.fetch!(layouts, "selection-msg-layout-assistant-0")

    mouse = fn action, x, y ->
      Breeze.Test.input(session, %{
        "mouse" => %{"button" => "left", "action" => action, "x" => x, "y" => y}
      })
    end

    mouse.("press", line.left, line.top)
    Breeze.Test.render!(session)
    mouse.("move", line.left + 5, line.top)
    screen = Breeze.Test.render!(session)
    assert screen =~ "Hello"
    assert Breeze.Test.metadata(session).assigns.text_selection.moved?
    mouse.("release", line.left + 5, line.top)
    assert_receive {:selection_copied, "Hello"}
    mouse.("release", line.left + 5, line.top)
    refute_receive {:selection_copied, _}

    Breeze.Test.render!(session)

    line =
      Map.fetch!(
        Breeze.ChildServer.layout_snapshot(session.pid).elements,
        "selection-msg-layout-assistant-0"
      )

    mouse.("press", line.left + 15, line.top)
    assert Breeze.Test.metadata(session).assigns.text_selection
    Breeze.Test.render!(session)
    mouse.("move", line.left + 11, line.top)
    assert Breeze.Test.metadata(session).assigns.text_selection.moved?
    mouse.("release", line.left + 11, line.top)
    assert_receive {:selection_copied, "世界"}

    mouse.("press", line.left, line.top)
    Breeze.Test.render!(session)
    mouse.("move", 110, 30)
    Breeze.Test.render!(session)
    mouse.("release", 110, 30)
    assert_receive {:selection_copied, "Hello wide 世界 and friends"}

    projection =
      put_in(
        projection,
        [
          :invocations,
          "inv-layout",
          Access.key(:coordination),
          Access.key(:pending_question)
        ],
        operator_question_fixture()
      )

    push_projection(session, projection)
    assert Breeze.Test.metadata(session).assigns.modal == :operator_question
    Breeze.Test.render!(session)

    line =
      Map.fetch!(
        Breeze.ChildServer.layout_snapshot(session.pid).elements,
        "selection-msg-layout-assistant-0"
      )

    mouse.("press", line.left, line.top)
    Breeze.Test.render!(session)
    mouse.("move", line.left + 5, line.top)
    Breeze.Test.render!(session)
    assert Breeze.Test.metadata(session).assigns.text_selection.moved?
    mouse.("release", line.left + 5, line.top)
    assert_receive {:selection_copied, "Hello"}
    Breeze.Test.input(session, "Escape")
    assert is_nil(Breeze.Test.metadata(session).assigns.text_selection)
  end

  test "selection freezes streamed text, cancels cleanly, and retains failed copies" do
    %{engine: engine} = start_isolated_stack([])

    session =
      start_session({120, 32},
        engine: engine,
        selection_copy: fn _ -> {:error, :clipboard_unavailable} end
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    projection =
      session
      |> long_response_projection()
      |> put_in([:messages, "msg-layout-assistant", :body], "stable answer")

    push_projection(session, projection)
    open_first_session(session)
    Breeze.Test.render!(session)

    line =
      Map.fetch!(
        Breeze.ChildServer.layout_snapshot(session.pid).elements,
        "selection-msg-layout-assistant-0"
      )

    selection_mouse(session, "press", line.left, line.top)
    Breeze.Test.render!(session)
    selection_mouse(session, "move", line.left + 6, line.top)
    token = Breeze.Test.metadata(session).assigns.text_selection.token

    push_projection(
      session,
      put_in(projection, [:messages, "msg-layout-assistant", :body], "replacement answer")
    )

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "stable answer"
    refute screen =~ "replacement answer"
    selection_mouse(session, "release", line.left + 6, line.top)
    assigns = Breeze.Test.metadata(session).assigns
    assert assigns.notice.message =~ "Could not copy selection"
    refute assigns.text_selection.dragging?
    assert session |> Breeze.Test.render!() |> plain() =~ "replacement answer"
    Breeze.Test.input(session, "Escape")
    Breeze.Test.info(session, {:selection_edge, token})
    assert is_nil(Breeze.Test.metadata(session).assigns.text_selection)

    Breeze.Test.render!(session)
    selection_mouse(session, "press", line.left, line.top)
    Breeze.Test.info(session, :resize)
    assert is_nil(Breeze.Test.metadata(session).assigns.text_selection)
  end

  test "dragging at a transcript edge scrolls while preserving the anchored range" do
    %{engine: engine} = start_isolated_stack([])
    owner = self()

    session =
      start_session({100, 24},
        engine: engine,
        selection_copy: fn text ->
          send(owner, {:edge_copy, text})
          :ok
        end
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    body = Enum.map_join(1..60, "\n\n", &"Line #{&1}")

    projection =
      session
      |> long_response_projection()
      |> put_in([:messages, "msg-layout-assistant", :body], body)

    push_projection(session, projection)
    open_first_session(session)
    Breeze.Test.render!(session)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()

    viewport =
      Map.fetch!(Breeze.ChildServer.layout_snapshot(session.pid).elements, assigns.timeline_id)

    for _ <- 1..8 do
      Breeze.Test.input(session, %{
        "mouse" => %{
          "button" => "wheel_up",
          "action" => "press",
          "x" => 6,
          "y" => viewport.top + 2
        }
      })

      Breeze.Test.render!(session)
    end

    layouts = Breeze.ChildServer.layout_snapshot(session.pid).elements

    {_id, line} =
      layouts
      |> Enum.filter(fn {id, box} ->
        String.starts_with?(id, "selection-msg-layout-assistant-") and
          box.top >= viewport.top and box.top < viewport.top + viewport.height
      end)
      |> Enum.min_by(fn {_id, box} -> box.top end)

    selection_mouse(session, "press", line.left, line.top)
    Breeze.Test.render!(session)
    initial = Breeze.Test.metadata(session).assigns.text_selection
    selection_mouse(session, "move", 70, viewport.top + viewport.height + 2)

    for _ <- 1..5 do
      Breeze.Test.info(session, {:selection_edge, initial.token})
      Breeze.Test.render!(session)
    end

    assert Breeze.Test.metadata(session).assigns.text_selection.scroll_offset >
             initial.scroll_offset

    selection_mouse(session, "release", 70, viewport.top + viewport.height + 2)
    assert_receive {:edge_copy, text}
    assert text =~ "Line"
    refute text =~ "Copy"
  end

  defp selection_mouse(session, action, x, y) do
    code = if action == "move", do: 32, else: 0
    suffix = if action == "release", do: "m", else: "M"
    assert {:ok, mouse} = Breeze.Mouse.decode("\e[<#{code};#{x + 1};#{y + 1}#{suffix}")
    Breeze.Test.input(session, %{"mouse" => mouse})
  end

  test "header estimates session spend at configured list prices" do
    path =
      Path.join(
        System.tmp_dir!(),
        "reycode-tui-pricing-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{"glm-4.6" => %{"input_per_mtok" => 2.0, "output_per_mtok" => 3.0}})
    )

    %{engine: engine} = start_isolated_stack(tui_pricing_path: path)
    config = RuntimeConfig.fresh(tui_pricing_path: path)
    session = start_session({120, 32}, engine: engine, config: config)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection =
      session
      |> long_response_projection()
      |> update_in([:invocations, "inv-layout", :participant], &%{&1 | model: "GLM-4.6"})
      |> put_in([:invocations, "inv-layout", :usage], %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 500_000
      })

    push_projection(session, projection)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()
    assert assigns.token_label == "reported 1500k tok · $3.50 session"

    unpriced =
      update_in(projection, [:invocations, "inv-layout", :participant], &%{&1 | model: "mystery"})

    push_projection(session, unpriced)
    assigns = session |> Breeze.Test.metadata() |> Map.fetch!(:assigns) |> State.prepare_render()
    assert assigns.token_label == "reported 1500k tok · session"
  end

  test "approval and queued presentation stay static and event-invariant across stale ticks" do
    %{engine: tui_engine_activity_static} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_activity_static)
    on_exit(fn -> Breeze.Test.stop(session) end)

    approval =
      long_response_projection(session)
      |> put_in([:messages, "msg-layout-assistant", :status], :streaming)
      |> put_in([:messages, "msg-layout-assistant", :body], "")
      |> put_in([:invocations, "inv-layout", :status], :waiting_tool_approval)
      |> put_in([:invocations, "inv-layout", :tool_runs], %{
        "bash" => %{
          id: "bash",
          tool: :bash,
          arguments: %{"command" => "mix test"},
          status: :awaiting_approval
        }
      })
      |> put_in([:invocations, "inv-layout", :tool_run_order], ["bash"])

    push_projection(session, approval)
    open_first_session(session)
    engine_sequence = Engine.snapshot(tui_engine_activity_static).sequence
    projection_sequence = Breeze.Test.metadata(session).assigns.projection.sequence
    paused = session |> Breeze.Test.render!() |> plain()
    assert paused =~ "Ⅱ · Paused · bash approval required · /tools"

    Enum.each(1..3, fn _ ->
      assert {:noreply, _focused} = Breeze.Test.info(session, {:activity_tick, make_ref()})
    end)

    assert session |> Breeze.Test.render!() |> plain() == paused
    assert Engine.snapshot(tui_engine_activity_static).sequence == engine_sequence
    assert Breeze.Test.metadata(session).assigns.projection.sequence == projection_sequence

    session_id = Breeze.Test.metadata(session).assigns.selected_session_id

    session_record = %{
      Map.fetch!(approval.sessions, session_id)
      | active_turn_id: nil,
        queued_turn_ids: ["turn-layout"]
    }

    turn = Map.put(Map.fetch!(approval.turns, "turn-layout"), :status, :queued)

    invocation =
      approval.invocations
      |> Map.fetch!("inv-layout")
      |> Map.put(:status, :queued)
      |> Map.put(:tool_runs, %{})
      |> Map.put(:tool_run_order, [])

    queued = %{
      approval
      | sessions: Map.put(approval.sessions, session_id, session_record),
        turns: Map.put(approval.turns, "turn-layout", turn),
        invocations: Map.put(approval.invocations, "inv-layout", invocation)
    }

    push_projection(session, queued)
    queued_screen = session |> Breeze.Test.render!() |> plain()
    assert queued_screen =~ "… · Queued"
    refute AnimationClock.armed?(Breeze.Test.metadata(session).assigns.animation_clock)
  end

  test "parallel invocation activity stays independently visible with deterministic header priority" do
    %{engine: tui_engine_activity_parallel} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_activity_parallel)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = long_response_projection(session)
    first = Map.fetch!(projection.invocations, "inv-layout")
    second_id = "inv-review"
    second_message_id = "msg-review"

    second = %{
      first
      | id: second_id,
        participant: %{first.participant | id: "review", name: "Review"},
        tool_runs: %{},
        tool_run_order: []
    }

    second_message = %{
      Map.fetch!(projection.messages, "msg-layout-assistant")
      | id: second_message_id,
        invocation_id: second_id,
        author: %{kind: :agent, id: "review", name: "Review"},
        status: :streaming,
        body: ""
    }

    session_id = first.session_id

    session_record = %{
      Map.fetch!(projection.sessions, session_id)
      | message_order: [second_message_id, "msg-layout-assistant", "msg-layout-user"]
    }

    turn =
      projection.turns
      |> Map.fetch!("turn-layout")
      |> Map.put(:invocation_order, ["inv-layout", second_id])

    projection = %{
      projection
      | sessions: Map.put(projection.sessions, session_id, session_record),
        turns: Map.put(projection.turns, "turn-layout", turn),
        invocations: Map.put(projection.invocations, second_id, second),
        messages: Map.put(projection.messages, second_message_id, second_message)
    }

    push_projection(session, projection)
    open_first_session(session)

    screen = session |> Breeze.Test.render!() |> plain()
    assert screen =~ "Thinking"
    assert screen =~ "Assistant"
    assert screen =~ "Review"
  end

  test "renders nested provider usage totals" do
    %{engine: tui_engine_11} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_11)

    projection =
      long_response_projection(session)
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
    assert plain(Breeze.Test.render!(session)) =~ "reported 16.6k tok"

    split_projection =
      put_in(
        projection,
        [:invocations, "inv-layout", :usage],
        %{"tokens" => %{"input" => 100, "output" => 5}}
      )

    assert %{sequence: _split} = push_projection(session, split_projection)

    assert plain(Breeze.Test.render!(session)) =~ "reported 105 tok"

    total_projection =
      put_in(split_projection, [:invocations, "inv-layout", :usage], %{"total_tokens" => 42})

    assert %{sequence: _total} = push_projection(session, total_projection)

    assert plain(Breeze.Test.render!(session)) =~ "reported 42 tok"
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
             String.contains?(m.body, File.read!("README.md"))
           end)
  end

  test "hides prior transcript history until the user explicitly resumes" do
    %{engine: engine, session_id: session_id} = start_isolated_stack([])

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
    %{engine: tui_engine_12} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_12)
    on_exit(fn -> Breeze.Test.stop(session) end)
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id

    type(session, "Keep this draft")

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, ctrl("p"))
    metadata = Breeze.Test.metadata(session)
    assert metadata.assigns.modal == :slash
    assert metadata.assigns.slash.query == "/"
    assert metadata.assigns.drafts[session_id] == "/"

    screen = Breeze.Test.render!(session)
    assert screen =~ "Connect a provider"

    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "Keep this draft"
    assert Breeze.Test.render!(session) =~ "Keep this draft"
  end

  test "Agent Hub renders Wave labels and durable peer-message counts" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = Engine.snapshot(engine)
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    session_record = projection.sessions[session_id]

    peer_messages =
      Enum.map(1..2, fn index ->
        %PeerMessage{
          id: "peer-#{index}",
          sender_invocation_id: "sibling",
          sender_name: "Nova",
          target_invocation_id: "child-wave",
          body: "coordination #{index}",
          created_sequence: projection.sequence
        }
      end)

    child = %Invocation{
      id: "child-wave",
      session_id: session_id,
      turn_id: "turn-wave",
      message_id: "message-wave",
      delegated_from_invocation_id: "parent-wave",
      delegated_from_tool_run_id: "run-wave",
      participant: %Participant{id: "luna", name: "Luna", kind: :task},
      label: "integration task",
      status: :running,
      coordination: %InvocationCoordination{peer_messages: peer_messages}
    }

    message = %Message{
      id: "message-wave",
      session_id: session_id,
      turn_id: "turn-wave",
      invocation_id: child.id,
      role: :assistant,
      status: :streaming
    }

    turn = %Turn{
      id: "turn-wave",
      session_id: session_id,
      input_kind: :detached,
      mode: :delegate,
      participant_id: child.participant.id,
      detached?: true,
      status: :running,
      invocation_order: [child.id],
      created_at: DateTime.utc_now() |> DateTime.add(-2, :second) |> DateTime.to_iso8601()
    }

    projection =
      projection
      |> put_in([:sessions, session_id], %{
        session_record
        | message_order: session_record.message_order ++ [message.id]
      })
      |> put_in([:messages, message.id], message)
      |> put_in([:invocations, child.id], child)
      |> put_in([:turns, turn.id], turn)

    push_projection(session, projection)
    type(session, "/hub")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")

    screen = Breeze.Test.render!(session)
    assert screen =~ "Agent Hub"
    assert screen =~ "Luna · running · 2 peer · integration task"
    assert screen =~ "Invocation  child-wave"
    assert screen =~ "Reported tokens"
    assert screen =~ "Estimated spend"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "T")
    assert Breeze.Test.render!(session) =~ "1 delegated · tree"

    review = %ToolAsk{
      request_id: "merge-review",
      tool: "merge",
      arguments: %{"diff" => "@@ -1 +1 @@\n-before\n+after"},
      workspace: "/tmp/worktree",
      requested_at: "2026-08-27T00:00:00Z"
    }

    merge_projection =
      put_in(projection, [:invocations, child.id], %{
        child
        | status: :waiting_tool_approval,
          pending_tool_review: review
      })

    push_projection(session, merge_projection)
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "M")
    merge_screen = Breeze.Test.render!(session)
    assert merge_screen =~ "Worktree checkpoint · Luna"
    assert merge_screen =~ "A Apply patch"
    assert merge_screen =~ "+after"
  end

  test "Tier Two modals render waiting questions, WorkPlans, and model tiers" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = Engine.snapshot(engine)
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    session_record = projection.sessions[session_id]
    primary = Enum.find(session_record.participants, &(&1.kind == :primary))

    question = %OperatorQuestion{
      id: "question-tui",
      tool_run_id: "run-question",
      questions: [
        %Item{
          id: "question-0",
          header: "Release",
          question: "Which implementation path?",
          options: [
            %{
              id: "option-0",
              label: "Safe",
              description: "Preserve compatibility",
              preview: "@@ -1 +1 @@\n-old\n+new"
            },
            %{id: "option-1", label: "Fast", description: "Prefer speed", preview: ""}
          ],
          recommended_id: "option-0",
          multi?: true,
          allow_other?: true
        },
        %Item{
          id: "question-1",
          header: "Region",
          question: "Which region?",
          options: [
            %{id: "option-0", label: "East", description: "", preview: ""},
            %{id: "option-1", label: "West", description: "", preview: ""}
          ],
          recommended_id: "option-1"
        }
      ],
      question: "Which implementation path?",
      options: [
        %{
          id: "option-0",
          label: "Safe",
          description: "Preserve compatibility",
          preview: "@@ -1 +1 @@\n-old\n+new"
        },
        %{id: "option-1", label: "Fast", description: "Prefer speed", preview: ""}
      ],
      recommended_id: "option-0",
      multi?: true,
      allow_other?: true,
      asked_at: "2026-08-27T00:00:00Z"
    }

    plan = %WorkPlan{
      phases: [
        %WorkPlan.Phase{
          name: "Build",
          items: [
            %WorkPlan.Item{name: "Implement", status: :in_progress, blocked_reason: nil},
            %WorkPlan.Item{name: "Test", status: :pending, blocked_reason: nil}
          ]
        }
      ],
      updated_at: "2026-08-27T00:00:00Z"
    }

    invocation = %Invocation{
      id: "invocation-tier-two",
      session_id: session_id,
      turn_id: "turn-tier-two",
      message_id: "message-tier-two",
      participant: primary,
      label: "assistant response",
      status: :waiting_operator,
      coordination: %InvocationCoordination{pending_question: question, work_plan: plan}
    }

    message = %Message{
      id: invocation.message_id,
      session_id: session_id,
      turn_id: invocation.turn_id,
      invocation_id: invocation.id,
      author: Author.from_participant(primary),
      role: :assistant,
      body: Enum.map_join(1..40, "\n\n", &"Transcript line #{&1}"),
      status: :streaming
    }

    turn = %Turn{
      id: invocation.turn_id,
      session_id: session_id,
      mode: :direct,
      status: :running,
      invocation_order: [invocation.id],
      created_at: "2026-08-27T00:00:00Z"
    }

    projection =
      projection
      |> put_in([:sessions, session_id], %{
        session_record
        | message_order: session_record.message_order ++ [message.id]
      })
      |> put_in([:messages, message.id], message)
      |> put_in([:invocations, invocation.id], invocation)
      |> put_in([:turns, turn.id], turn)

    questionless =
      put_in(
        projection,
        [
          :invocations,
          invocation.id,
          Access.key(:coordination),
          Access.key(:pending_question)
        ],
        nil
      )
      |> put_in([:invocations, invocation.id, Access.key(:status)], :running)

    push_projection(session, projection)
    assert Breeze.Test.metadata(session).assigns.modal == :operator_question

    waiting_screen = Breeze.Test.render!(session)
    assert waiting_screen =~ "Answer required"
    assert waiting_screen =~ "Assistant is waiting for your answer"
    assert waiting_screen =~ "Which implementation path?"
    refute waiting_screen =~ "Message Assistant"
    refute waiting_screen =~ "Ask anything"

    timeline_id = State.timeline_id(session_id)
    assert {:noreply, ^timeline_id, true} = Breeze.ChildServer.set_focus(session.pid, timeline_id)

    {Breeze.Implicit.Scroll, %{offset_y: timeline_offset}} =
      session
      |> Breeze.Test.metadata()
      |> Map.fetch!(:implicit_state)
      |> Map.fetch!(timeline_id)

    assert Breeze.Test.metadata(session).assigns.operator_question.option_index == 0
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert Breeze.Test.metadata(session).assigns.operator_question.option_index == 2

    assert {Breeze.Implicit.Scroll, %{offset_y: ^timeline_offset}} =
             Map.fetch!(Breeze.Test.metadata(session).implicit_state, timeline_id)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert Breeze.Test.metadata(session).assigns.operator_question.option_index == 0

    assert {Breeze.Implicit.Scroll, %{offset_y: ^timeline_offset}} =
             Map.fetch!(Breeze.Test.metadata(session).implicit_state, timeline_id)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, " ")

    assert {:noreply, _focused, _changed?} =
             Breeze.ChildServer.set_focus(session.pid, "copy-#{message.id}")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.operator_question.tab_index == 1
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowLeft")

    push_projection(session, questionless)
    assert Breeze.Test.metadata(session).assigns.modal == nil
    Breeze.Test.event(session, "prompt_changed", %{value: "/plan", cursor: 5})
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :work_plan
    Breeze.Test.event(session, "prompt_changed", %{value: "preserved draft", cursor: 15})
    push_projection(session, projection)
    assert Breeze.Test.metadata(session).assigns.modal == :work_plan
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Escape")

    assert Breeze.Test.metadata(session).assigns.modal == :operator_question
    question_screen = Breeze.Test.render!(session)
    assert question_screen =~ "Answer required"
    assert question_screen =~ "Assistant is waiting for your answer"
    assert question_screen =~ "Which implementation path?"
    assert question_screen =~ "Safe · recommended"
    assert question_screen =~ "@@ -1 +1 @@"
    assert question_screen =~ "1 Release"
    assert question_screen =~ "2 Region"
    assert question_screen =~ "Review"
    assert question_screen =~ "Other · type a custom answer"
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "preserved draft"

    mouse_action(session, "Safe · recommended", "press")
    mouse_action(session, "Safe · recommended", "release")

    assert Breeze.Test.metadata(session).assigns.operator_question.answers["question-0"].option_ids ==
             ["option-0"]

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render!(session) =~ "Which region?"
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "2")
    review_screen = Breeze.Test.render!(session)
    assert review_screen =~ "Review answers"
    assert review_screen =~ "Release · Safe"
    assert review_screen =~ "Region · West"
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")

    Breeze.Test.event(session, "prompt_changed", %{value: "/plan", cursor: 5})
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    plan_screen = Breeze.Test.render!(session)
    assert plan_screen =~ "WorkPlan"
    assert plan_screen =~ "▶ Implement"
    assert plan_screen =~ "○ Test"
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Escape")

    refute Enum.any?(ReyCode.Capabilities.commands(), &(&1.command == "/tier"))
  end

  test "an unknown slash command is never posted to the session" do
    %{engine: tui_engine_13} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_13)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/bogus")

    assert Breeze.Test.render!(session) =~ "No matching commands"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    assert screen =~ "Unknown command"
    refute screen =~ "No matching commands"
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    assert Breeze.Test.metadata(session).assigns.drafts[session_id] == "/bogus"
  end

  test "runs a slash command with the prompt shortcut" do
    %{engine: tui_engine_14} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_14)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/theme")

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = Breeze.Test.render!(session)
    refute screen =~ "ReyCode commands"
  end

  test "opens retained tool artifacts and pages their bounded content" do
    root = Path.join(System.tmp_dir!(), "tui-artifacts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    config =
      configured_runtime(
        artifact_root: root,
        artifact_spool_threshold_bytes: 32,
        artifact_preview_bytes: 32,
        artifact_max_bytes: 1_024,
        artifact_max_count: 4
      )

    spooled =
      ArtifactStore.spool(
        Result.ok(String.duplicate("retained output\n", 20)),
        config.artifacts,
        "inv-artifact",
        "run-artifact"
      )

    artifact_id = spooled.metadata["artifact_id"]

    %{engine: engine} =
      start_isolated_stack(
        artifact_root: root,
        artifact_spool_threshold_bytes: 32,
        artifact_preview_bytes: 32,
        artifact_max_bytes: 1_024,
        artifact_max_count: 4
      )

    session = start_session({120, 32}, engine: engine, config: config)
    on_exit(fn -> Breeze.Test.stop(session) end)

    type(session, "/artifacts")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    list_screen = Breeze.Test.render!(session)
    assert list_screen =~ "Bounded ToolRun output spool"
    assert list_screen =~ artifact_id

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    detail_screen = Breeze.Test.render!(session)
    assert detail_screen =~ "artifact://#{artifact_id}"
    assert detail_screen =~ "retained output"
  end

  test "opens the deterministic capability help modal" do
    %{engine: tui_engine_15} = start_isolated_stack([])
    session = start_session({120, 32}, engine: tui_engine_15)
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
    assert screen =~ "model APIs"
    assert screen =~ "Type / for commands"
  end

  @tag :ui_latency
  test "palette navigation and streamed text remain current with cached long responses" do
    %{engine: engine} = start_isolated_stack([])
    session = start_session({120, 32}, engine: engine)
    on_exit(fn -> Breeze.Test.stop(session) end)

    projection = long_response_projection(session)

    body =
      String.duplicate(
        "## Streaming response\n\n```elixir\ndef run(value), do: {:ok, value}\n```\n\n",
        500
      )

    projection = put_in(projection, [:messages, "msg-layout-assistant", :body], body)
    push_projection(session, projection)
    open_first_session(session)
    Breeze.Test.event(session, "prompt_changed", %{value: "/", cursor: 1})
    Breeze.Test.render!(session)

    count =
      session
      |> Breeze.Test.metadata()
      |> Map.fetch!(:assigns)
      |> State.prepare_render()
      |> Map.fetch!(:slash_rows)
      |> length()

    for index <- 1..10 do
      Breeze.Test.input(session, "ArrowDown")
      assert Breeze.Test.metadata(session).assigns.slash.index == rem(index, count)
      assert Breeze.Test.render!(session) =~ "Streaming response"
    end

    Breeze.Test.input(session, "Escape")

    for index <- 1..3 do
      next =
        put_in(
          projection,
          [:messages, "msg-layout-assistant", :body],
          body <> "\n\nStreamed update #{index}"
        )

      push_projection(session, next)
      assert Breeze.Test.render!(session) =~ "Streamed update #{index}"
    end
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
    session_id = List.first(projection.session_order)

    %{engine: engine, store: store, session_id: session_id, config: config}
  end

  defp open_first_session(session) do
    type(session, "/resume")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
  end

  defp type(session, text) do
    Breeze.Test.render!(session)

    for key <- String.graphemes(text) do
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, key)
      Breeze.Test.render!(session)
    end
  end

  defp start_session(size, opts) do
    Breeze.Test.start!(ReyCode.TUI,
      size: size,
      theme: ReyCode.Theme.default(),
      global_keybindings: ReyCode.TUI.global_keybindings(),
      start_opts:
        Keyword.take(opts, [:engine, :config, :memory_store, :workspace, :selection_copy])
    )
  end

  defp temporary_workspace(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tui_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, canonical} = CanonicalPath.resolve(path)
    canonical
  end

  defp workspace_session_ids(engine, workspace) do
    projection = Engine.snapshot(engine)

    Enum.filter(projection.session_order, fn session_id ->
      projection.sessions[session_id].workspace == workspace
    end)
  end

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  defp mouse_action(session, label, action) do
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

  defp long_response_projection(session) do
    engine = Breeze.Test.metadata(session).assigns.engine
    session_id = Breeze.Test.metadata(session).assigns.selected_session_id
    projection = Engine.snapshot(engine)
    session_record = projection.sessions[session_id]
    turn_id = "turn-layout"
    invocation_id = "inv-layout"
    user_message_id = "msg-layout-user"
    assistant_message_id = "msg-layout-assistant"

    user = %{
      id: user_message_id,
      session_id: session_id,
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
      session_id: session_id,
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
      message_id: assistant_message_id,
      notes: [],
      participant: %{
        id: "assistant",
        name: "Assistant",
        provider: :opencode,
        model: "openai/gpt-5.4-mini"
      },
      session_id: session_id,
      turn_id: turn_id,
      status: :running,
      coordination: %InvocationCoordination{},
      attempt: 1,
      usage: %{"prompt_tokens" => 12_000, "completion_tokens" => 400},
      pending_tool_review: nil,
      delegated_from_invocation_id: nil,
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
            "metadata" => %{
              "_tui_diff" => %{
                "lines" => ["@@ patch 1 @@", "-hello", "no-change line", "+hello world"],
                "truncated" => false
              }
            }
          }
        }
      },
      tool_run_order: ["run-1"]
    }

    running_turn = %{
      mode: :direct,
      invocation_order: [invocation_id],
      status: :running,
      created_at:
        DateTime.utc_now()
        |> DateTime.add(-5, :second)
        |> DateTime.to_iso8601()
    }

    projection
    |> put_in([:sessions, session_id], %{
      session_record
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

  defp operator_question_fixture do
    item = %Item{
      id: "question-0",
      header: "Choice",
      question: "Continue?",
      options: [
        %{id: "option-0", label: "Yes", description: "", preview: ""},
        %{id: "option-1", label: "No", description: "", preview: ""}
      ],
      recommended_id: nil
    }

    %OperatorQuestion{
      id: "selection-question",
      tool_run_id: "selection-run",
      questions: [item],
      question: item.question,
      options: item.options,
      recommended_id: nil,
      asked_at: "now"
    }
  end

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
