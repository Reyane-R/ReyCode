defmodule ReyCode.TUI.ActivityAnimationTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.Catalog
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.AnimationClock

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule BlockingCatalog do
    use GenServer

    alias ReyCode.Provider.{Catalog, Runtime}
    alias ReyCode.TUI.ActivityAnimationTest.BlockingProvider

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:registry, _from, state), do: {:reply, state.registry, state}

    def handle_call(:snapshot, _from, state) do
      snapshot = %Catalog.Snapshot{
        generation: 1,
        providers: %{
          simulator: %{
            id: :simulator,
            name: "Simulator",
            status: :configured,
            models: [],
            credential_count: 0
          }
        }
      }

      {:reply, snapshot, state}
    end

    def handle_call({action, _provider, _model}, _from, state)
        when action in [:resolve, :resolve_when_ready] do
      runtime = %Runtime{module: BlockingProvider, status: :available, executable: state.test_pid}
      {:reply, {:ok, runtime}, state}
    end
  end

  defmodule BlockingProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Failure
    alias ReyCode.Provider.{Frame, Response, Runtime}

    @impl true
    def stream(%Runtime{executable: test_pid}, request, emit) do
      send(test_pid, {:provider_waiting, request.invocation_id, self()})

      receive do
        :complete ->
          :ok = emit.(Frame.text_delta(request.resume_from + 1, "done"))
          {:ok, Response.new(text: "done", usage: %{"total_tokens" => 2})}
      after
        10_000 -> {:error, Failure.new(:internal, "blocking provider timed out")}
      end
    end
  end

  test "silent provider animates without events, then terminal state stops and ignores stale ticks" do
    stack = start_stack()
    session = start_session(stack)
    on_exit(fn -> Breeze.Test.stop(session) end)

    send_prompt(session, "silent work")
    assert_receive {:provider_waiting, _invocation_id, provider_pid}, 5_000
    assert_receive {:scheduled, token, 120, _timer_ref}, 5_000

    projection = Wait.projection(@engine, &active_turn/1)
    push_projection(session, projection)
    engine_sequence = projection.sequence
    tui_sequence = Breeze.Test.metadata(session).assigns.projection.sequence
    turn = active_turn_record(projection)
    started_ms = iso_ms(turn.created_at)

    first = session |> Breeze.Test.render!() |> plain()
    assert first =~ "Thinking"

    assert {:noreply, _focused} =
             Breeze.Test.info(session, {:activity_tick, token, started_ms + 2_000})

    assert_receive {:scheduled, next_token, 120, _next_ref}

    second = session |> Breeze.Test.render!() |> plain()
    assert second =~ "2s"
    refute spinner_glyph(first) == spinner_glyph(second)
    assert Engine.snapshot(@engine).sequence == engine_sequence
    assert Breeze.Test.metadata(session).assigns.projection.sequence == tui_sequence

    final_token = drive_ticks(session, next_token, started_ms + 3_000, 9)
    assert Engine.snapshot(@engine).sequence == engine_sequence
    assert Breeze.Test.metadata(session).assigns.projection.sequence == tui_sequence

    send(provider_pid, :complete)
    terminal = Wait.projection(@engine, &terminal_turn/1)
    push_projection(session, terminal)
    assert_receive {:cancelled, _timer_ref}, 5_000
    refute AnimationClock.armed?(Breeze.Test.metadata(session).assigns.animation_clock)

    terminal_screen = session |> Breeze.Test.render!() |> plain()
    assert terminal_screen =~ "✓ · Completed"
    refute terminal_screen =~ "Thinking"

    assert {:noreply, _focused} =
             Breeze.Test.info(session, {:activity_tick, final_token, started_ms + 20_000})

    assert session |> Breeze.Test.render!() |> plain() == terminal_screen
    refute_receive {:scheduled, _token, _delay, _timer_ref}
  end

  test "reduced motion uses a static glyph and one-second cadence" do
    stack = start_stack(tui_reduced_motion: true)
    session = start_session(stack)
    on_exit(fn -> Breeze.Test.stop(session) end)

    send_prompt(session, "reduced motion")
    assert_receive {:provider_waiting, _invocation_id, _provider_pid}, 5_000
    assert_receive {:scheduled, token, 1_000, _timer_ref}, 5_000

    projection = Wait.projection(@engine, &active_turn/1)
    push_projection(session, projection)
    started_ms = projection |> active_turn_record() |> Map.fetch!(:created_at) |> iso_ms()

    first = session |> Breeze.Test.render!() |> plain()
    assert first =~ "• · Thinking"

    assert {:noreply, _focused} =
             Breeze.Test.info(session, {:activity_tick, token, started_ms + 2_000})

    assert_receive {:scheduled, _next_token, 1_000, _next_ref}

    second = session |> Breeze.Test.render!() |> plain()
    assert second =~ "• · Thinking"
    assert second =~ "2s"
  end

  test "leaving the active Session cancels its clock and stale ticks cannot restart it" do
    stack = start_stack()
    session = start_session(stack)
    on_exit(fn -> Breeze.Test.stop(session) end)

    send_prompt(session, "switch away")
    assert_receive {:provider_waiting, _invocation_id, _provider_pid}, 5_000
    assert_receive {:scheduled, token, 120, timer_ref}, 5_000

    assert_noreply(Breeze.Test.input(session, %{"ctrlKey" => true, "key" => "n"}))
    assert_receive {:cancelled, ^timer_ref}, 5_000
    refute AnimationClock.armed?(Breeze.Test.metadata(session).assigns.animation_clock)

    assert {:noreply, _focused} = Breeze.Test.info(session, {:activity_tick, token})
    refute_receive {:scheduled, _token, _delay, _timer_ref}
  end

  defp drive_ticks(_session, token, _now_ms, 0), do: token

  defp drive_ticks(session, token, now_ms, count) do
    assert {:noreply, _focused} = Breeze.Test.info(session, {:activity_tick, token, now_ms})
    assert_receive {:scheduled, next_token, 120, _timer_ref}
    drive_ticks(session, next_token, now_ms + 120, count - 1)
  end

  defp start_stack(overrides \\ []) do
    workspace = Path.join(System.tmp_dir!(), "activity_tui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_activity_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({BlockingCatalog, test_pid: self(), registry: @event_registry})

    config =
      [
        allow_simulator_provider: true,
        global_concurrency: 2,
        workspace_concurrency: 1,
        workspace_roots: [workspace]
      ]
      |> Keyword.merge(overrides)
      |> RuntimeConfig.fresh()

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: catalog,
       agent_delay_ms: 0,
       config: config}
    )

    session_id = Engine.snapshot(@engine).session_order |> List.last()
    primary = Engine.snapshot(@engine).sessions[session_id].participants |> List.first()
    assert :ok = Engine.configure_participants(session_id, [primary.id], :simulator, nil, @engine)

    test_pid = self()

    schedule = fn token, delay_ms ->
      timer_ref = make_ref()
      send(test_pid, {:scheduled, token, delay_ms, timer_ref})
      timer_ref
    end

    cancel = fn timer_ref ->
      send(test_pid, {:cancelled, timer_ref})
      true
    end

    %{catalog: catalog, config: config, schedule: schedule, cancel: cancel}
  end

  defp start_session(stack) do
    Breeze.Test.start!(ReyCode.TUI,
      size: {120, 32},
      theme: ReyCode.Theme.default(),
      global_keybindings: ReyCode.TUI.global_keybindings(),
      start_opts: [
        engine: @engine,
        provider_catalog: stack.catalog,
        config: stack.config,
        animation_schedule: stack.schedule,
        animation_style: :unicode,
        animation_cancel: stack.cancel
      ]
    )
  end

  defp send_prompt(session, text) do
    Breeze.Test.render!(session)

    Enum.each(String.graphemes(text), fn grapheme ->
      assert {:noreply, _focused, _changed?} = Breeze.Test.input(session, grapheme)
      Breeze.Test.render!(session)
    end)

    assert {:noreply, _focused, _changed?} =
             Breeze.Test.input(session, %{"ctrlKey" => true, "key" => "s"})
  end

  defp push_projection(session, projection) do
    current = Breeze.Test.metadata(session).assigns.projection.sequence

    projection =
      if projection.sequence > current,
        do: projection,
        else: %{projection | sequence: current + 1}

    assert {:noreply, _focused} = Breeze.Test.info(session, {:projection_snapshot, projection})
    projection
  end

  defp active_turn(projection) do
    session = selected_room(projection)
    if session.active_turn_id, do: projection, else: false
  end

  defp terminal_turn(projection) do
    turn = active_or_recent_turn(projection)
    if turn && turn.status == :terminal, do: projection, else: false
  end

  defp active_turn_record(projection), do: active_or_recent_turn(projection)

  defp active_or_recent_turn(projection) do
    session = selected_room(projection)

    turn_id =
      session.active_turn_id ||
        Enum.find_value(session.message_order, fn message_id ->
          Map.fetch!(projection.messages, message_id).turn_id
        end)

    turn_id && Map.get(projection.turns, turn_id)
  end

  defp assert_noreply({:noreply, _focused}), do: :ok
  defp assert_noreply({:noreply, _focused, _changed?}), do: :ok

  defp selected_room(projection) do
    session_id = List.last(projection.session_order)
    Map.fetch!(projection.sessions, session_id)
  end

  defp iso_ms(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    DateTime.to_unix(datetime, :millisecond)
  end

  defp spinner_glyph(screen) do
    case Regex.run(~r/([⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]) · Thinking/, screen, capture: :all_but_first) do
      [glyph] -> glyph
      _none -> nil
    end
  end

  defp plain(screen), do: Regex.replace(~r/\e\[[0-9;]*m/, screen, "")
end
