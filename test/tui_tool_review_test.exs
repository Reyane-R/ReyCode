defmodule ReyCode.TUI.ToolReviewTest do
  @moduledoc """
  Exercises owner approval through the public TUI against durable ToolRuns,
  including unselected Enter, explicit decisions, and cancellation.
  """

  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.Notice

  setup do
    fixture_root =
      Path.join([File.cwd!(), ".reycode", "tool-review-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(fixture_root)
    on_exit(fn -> File.rm_rf!(fixture_root) end)
    out_path = Path.join(fixture_root, "out.txt")
    relative_path = Path.relative_to_cwd(out_path)

    %{engine: engine, config: config, store: store} =
      start_isolated_stack(
        seed: 0,
        delay_ms: 0,
        tool_requests: [
          %{tool: "write", arguments: %{"path" => relative_path, "content" => "approved-content"}}
        ]
      )

    snapshot = Engine.snapshot(engine)
    session_id = Enum.find(snapshot.session_order, &(snapshot.sessions[&1].slug == "reycode"))
    assert {:ok, turn_id} = Engine.post_message(session_id, "Review this write", :compare, engine)
    Wait.invocation_status(engine, turn_id, :waiting_tool_approval)

    on_exit(fn ->
      if GenServer.whereis(engine), do: Engine.cancel_turn(turn_id, "test cleanup", engine)
    end)

    %{
      engine: engine,
      config: config,
      store: store,
      turn_id: turn_id,
      out_path: out_path
    }
  end

  test "opens the persisted request and explicit D denies that exact run atomically", %{
    engine: engine,
    config: config,
    store: store,
    turn_id: turn_id,
    out_path: out_path
  } do
    session = start_session(engine, config)
    review = open_review(session)
    screen = plain(Breeze.Test.render!(session))

    assert screen =~ "write"
    assert screen =~ "out.txt"
    assert screen =~ "16 bytes"
    assert screen =~ "approved-content"
    assert is_nil(review.index)
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "d")
    denial = assert_resolution(session, store, review, "deny")
    assert denied_invocation?(engine, turn_id)
    refute File.exists?(out_path)

    # Denial and terminal failure are one durable append, with adjacent sequences.
    failure = Enum.find(EventStore.load(store), &(&1.sequence == denial.sequence + 1))
    assert failure.type == :invocation_failed
    assert failure.data["invocation_id"] == review.invocation_id
  end

  test "Enter without a choice leaves the same request pending and performs no write", %{
    engine: engine,
    config: config,
    store: store,
    turn_id: turn_id,
    out_path: out_path
  } do
    session = start_session(engine, config)
    review = open_review(session)
    events = EventStore.load(store)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assigns = Breeze.Test.metadata(session).assigns
    assert assigns.modal == :tool_review
    assert is_nil(assigns.tool_review.index)
    assert %Notice{severity: :info} = assigns.notice
    refute plain(Breeze.Test.render!(session)) =~ "Error ·"
    assert waiting?(engine, turn_id)

    assert Engine.snapshot(engine).invocations[review.invocation_id].pending_tool_review ==
             review.review

    assert EventStore.load(store) == events
    refute File.exists?(out_path)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert Breeze.Test.metadata(session).assigns.tool_review.index == 1
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert_resolution(session, store, review, "deny")
    refute File.exists?(out_path)
  end

  test "ArrowDown selects approval and Enter executes only the displayed run", %{
    engine: engine,
    config: config,
    store: store,
    turn_id: turn_id,
    out_path: out_path
  } do
    session = start_session(engine, config)
    review = open_review(session)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert Breeze.Test.metadata(session).assigns.tool_review.index == 0
    assert waiting?(engine, turn_id)
    refute File.exists?(out_path)
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "Enter")
    assert_resolution(session, store, review, "approve")
    Wait.terminal_turn(engine, turn_id)
    assert File.read!(out_path) == "approved-content"
  end

  test "explicit A overrides the highlighted denial without a second confirmation", %{
    engine: engine,
    config: config,
    store: store,
    turn_id: turn_id,
    out_path: out_path
  } do
    session = start_session(engine, config)
    review = open_review(session)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowUp")
    assert Breeze.Test.metadata(session).assigns.tool_review.index == 1
    assert {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "A")
    assert_resolution(session, store, review, "approve")
    Wait.terminal_turn(engine, turn_id)
    assert File.read!(out_path) == "approved-content"
  end

  test "Escape preserves pending approval and reopening discards any old selection", %{
    engine: engine,
    config: config,
    store: store,
    turn_id: turn_id,
    out_path: out_path
  } do
    session = start_session(engine, config)
    review = open_review(session)
    events = EventStore.load(store)

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "ArrowDown")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")
    assert is_nil(Breeze.Test.metadata(session).assigns.modal)
    refute File.exists?(out_path)

    reopened = open_review(session)
    assert reopened.review.request_id == review.review.request_id
    assert is_nil(reopened.index)
    assert waiting?(engine, turn_id)
    assert EventStore.load(store) == events
  end

  defp open_review(session) do
    type(session, "/tools")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assigns = Breeze.Test.metadata(session).assigns
    assert assigns.modal == :tool_review
    assigns.tool_review
  end

  defp assert_resolution(session, store, review, decision) do
    assigns = Breeze.Test.metadata(session).assigns
    assert is_nil(assigns.modal)
    assert %Notice{severity: :success} = assigns.notice

    [event] = Enum.filter(EventStore.load(store), &(&1.type == :tool_run_approval_resolved))
    assert event.data["invocation_id"] == review.invocation_id
    assert event.data["tool_run_id"] == review.review.request_id
    assert event.data["decision"] == decision
    event
  end

  defp denied_invocation?(engine, turn_id) do
    snapshot = Engine.snapshot(engine)

    Enum.any?(snapshot.turns[turn_id].invocation_order, fn id ->
      error = snapshot.invocations[id].error
      error != nil and error.category == :tool_denied
    end)
  end

  defp start_session(engine, config) do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 44},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings(),
        start_opts: [engine: engine, config: config]
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    session
  end

  defp type(session, text) do
    Breeze.Test.render!(session)

    for key <- String.graphemes(text) do
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, key)
      Breeze.Test.render!(session)
    end
  end

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")

  defp waiting?(engine, turn_id) do
    snapshot = Engine.snapshot(engine)

    Enum.any?(snapshot.turns[turn_id].invocation_order, fn id ->
      snapshot.invocations[id].status == :waiting_tool_approval
    end)
  end

  defp start_isolated_stack(simulator_opts) do
    suffix = System.unique_integer([:positive])

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tool_review_#{System.pid()}_#{suffix}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    agent_registry = :"tool_review_agents_#{suffix}"
    event_registry = :"tool_review_events_#{suffix}"
    agent_supervisor = :"tool_review_sup_#{suffix}"
    engine = :"tool_review_engine_#{suffix}"

    start_supervised!({Registry, keys: :unique, name: agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_supervisor})

    config = RuntimeConfig.load!()

    opts = [
      name: engine,
      event_store: store,
      agent_supervisor: agent_supervisor,
      agent_registry: agent_registry,
      event_registry: event_registry,
      provider_catalog: ReyCode.Provider.Catalog,
      agent_delay_ms: 0,
      simulator_opts: simulator_opts,
      config: config
    ]

    start_supervised!(Supervisor.child_spec({Engine, opts}, restart: :temporary))
    %{engine: engine, config: config, store: store}
  end
end
