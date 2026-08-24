defmodule ReyCode.TUI.ToolReviewTest do
  @moduledoc """
  Feature-owned coverage for the tool-approval modal exercised through the
  public TUI flow: open via `/tools`, render exact request details, cancel,
  and deny without side effects.
  """

  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine

  setup do
    %{engine: engine, config: config} =
      start_isolated_stack(
        seed: 0,
        delay_ms: 0,
        tool_requests: [
          %{tool: "write", arguments: %{"path" => "out.txt", "content" => "approved-content"}}
        ]
      )

    snapshot = Engine.snapshot(engine)

    room_id = Enum.find(snapshot.room_order, &(snapshot.rooms[&1].slug == "reycode"))
    assert {:ok, turn_id} = Engine.post_message(room_id, "Review this write", :compare, engine)
    wait_until_waiting(engine, turn_id)

    out_path = Path.join(File.cwd!(), "out.txt")

    on_exit(fn ->
      if GenServer.whereis(engine), do: Engine.cancel_turn(turn_id, "test cleanup", engine)

      File.rm(out_path)
    end)

    %{engine: engine, config: config, room_id: room_id, turn_id: turn_id, out_path: out_path}
  end

  test "opens from the palette and renders the exact persisted request", %{
    engine: engine,
    config: config,
    turn_id: turn_id,
    out_path: out_path
  } do
    {session, _} = start_session(turn_id, engine, config)

    type(session, "/tools")
    assert Breeze.Test.render!(session) =~ "Review a pending tool request"

    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    screen = plain(Breeze.Test.render!(session))

    assert Breeze.Test.metadata(session).assigns.modal == :tool_review
    assert screen =~ "Tool approval"
    assert screen =~ "This request is waiting for owner approval."
    assert screen =~ "write"
    assert screen =~ "WRITE PATH"
    assert screen =~ "out.txt"
    assert screen =~ "CONTENT SIZE"
    assert screen =~ "16 bytes"
    assert screen =~ "CONTENT PREVIEW"
    assert screen =~ "approved-content"
    assert screen =~ "WORKSPACE"

    refute File.exists?(out_path)

    deny_selected(session)
    assert denied_invocation?(engine, turn_id)
    refute File.exists?(out_path)
  end

  test "escape closes the review while the request stays pending", %{
    engine: engine,
    config: config,
    turn_id: turn_id,
    out_path: out_path
  } do
    {session, _} = start_session(turn_id, engine, config)

    type(session, "/tools")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert {:noreply, "prompt", true} = Breeze.Test.input(session, "Escape")

    refute Breeze.Test.render!(session) =~ "Tool approval"
    refute File.exists?(out_path)

    # The approval is still durable: reopening resumes the same review.
    type(session, "/tools")
    assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, "Enter")
    assert Breeze.Test.metadata(session).assigns.modal == :tool_review
    assert waiting?(engine, turn_id)
  end

  defp deny_selected(session) do
    {:noreply, "prompt", _changed?} = Breeze.Test.input(session, "d")
    wait_until_notice(session, "Tool request denied")
    refute Breeze.Test.render!(session) =~ "Tool approval"
  end

  defp denied_invocation?(engine, turn_id) do
    snapshot = Engine.snapshot(engine)

    Enum.any?(snapshot.turns[turn_id].invocation_order, fn id ->
      error = snapshot.invocations[id].error
      error != nil and error["category"] == "tool_denied"
    end)
  end

  defp wait_until_notice(session, text, attempts \\ 100)

  defp wait_until_notice(session, _text, 0) do
    flunk("notice never appeared; screen:\n#{plain(Breeze.Test.render!(session))}")
  end

  defp wait_until_notice(session, text, attempts) do
    if Breeze.Test.render!(session) =~ text do
      :ok
    else
      Process.sleep(25)
      wait_until_notice(session, text, attempts - 1)
    end
  end

  defp start_session(turn_id, engine, config) do
    session =
      Breeze.Test.start!(ReyCode.TUI,
        size: {120, 44},
        theme: ReyCode.Theme.default(),
        global_keybindings: ReyCode.TUI.global_keybindings(),
        start_opts: [engine: engine, config: config]
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    {session, turn_id}
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
      invocation = snapshot.invocations[id]
      invocation.status == :waiting_tool_approval or invocation.pending_tool_review != nil
    end)
  end

  defp wait_until_waiting(engine, turn_id, attempts \\ 200)

  defp wait_until_waiting(_engine, _turn_id, 0),
    do: flunk("no invocation reached waiting_tool_approval")

  defp wait_until_waiting(engine, turn_id, attempts) do
    if waiting?(engine, turn_id) do
      :ok
    else
      Process.sleep(25)
      wait_until_waiting(engine, turn_id, attempts - 1)
    end
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
    %{engine: engine, config: config}
  end
end
