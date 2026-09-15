defmodule ReyCode.LiveStreamDeliveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.{Frame, Response, Runtime}
  alias ReyCode.Test.Wait

  defmodule Catalog do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({action, _, _}, _from, owner)
        when action in [:resolve, :resolve_when_ready] do
      {:reply,
       {:ok,
        %Runtime{
          module: ReyCode.LiveStreamDeliveryTest.Provider,
          status: :available,
          config: owner
        }}, owner}
    end
  end

  defmodule Provider do
    @behaviour ReyCode.Provider
    @impl true
    def stream(%Runtime{config: owner}, request, emit) do
      send(owner, {:provider_ready, self()})

      receive do
        :emit -> :ok
      after
        5_000 -> raise "Test provider was not started"
      end

      :ok = emit.(Frame.agent_note(request.resume_from + 1, "Checking the evidence live"))
      send(owner, {:reasoning_paused, self()})

      receive do
        :answer -> :ok
      after
        5_000 -> raise "Test answer was not requested"
      end

      :ok = emit.(Frame.text_delta(request.resume_from + 2, "First answer fragment"))
      send(owner, {:provider_paused, self()})

      receive do
        :finish ->
          :ok = emit.(Frame.text_delta(request.resume_from + 3, " then finished"))
          {:ok, Response.new(text: "First answer fragment then finished")}

        :fail ->
          {:error, ReyCode.Failure.new(:internal, "Scripted provider failure")}
      after
        5_000 -> {:error, ReyCode.Failure.new(:timeout, "Test provider was not released")}
      end
    end
  end

  for ending <- [:finish, :fail, :cancel] do
    @tag :tmp_dir
    @tag ending: ending
    test "reasoning and answer reach the transcript before #{ending}", %{
      tmp_dir: workspace,
      ending: ending
    } do
      store =
        start_supervised!({EventStore, name: nil, path: Path.join(workspace, "events.sqlite3")})

      start_supervised!({Registry, keys: :unique, name: __MODULE__.Agents})
      start_supervised!({Registry, keys: :duplicate, name: __MODULE__.Events})
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.Workers})
      catalog = start_supervised!({Catalog, self()})

      config =
        RuntimeConfig.fresh(
          workspace_roots: [workspace],
          provider_discovery: false,
          tui_update_check: false
        )

      engine =
        start_supervised!(
          {Engine,
           name: __MODULE__.Engine,
           event_store: store,
           agent_registry: __MODULE__.Agents,
           event_registry: __MODULE__.Events,
           agent_supervisor: __MODULE__.Workers,
           provider_catalog: catalog,
           config: config,
           agent_delay_ms: 0}
        )

      {:ok, session_id} = Engine.create_blank_session("Live streaming", workspace, engine)

      :ok =
        Engine.configure_participants(session_id, ["assistant"], :zai_coding, "glm-4.7", engine)

      {:ok, turn_id} = Engine.post_message(session_id, "Answer in fragments", :direct, engine)
      assert_receive {:provider_ready, worker}, 1_000

      view =
        Breeze.Test.start!(ReyCode.TUI,
          size: {100, 30},
          start_opts: [engine: engine, config: config, workspace: workspace]
        )

      on_exit(fn -> Breeze.Test.stop(view) end)
      Breeze.Test.event(view, "prompt_submitted", %{value: "/resume #{session_id}"})
      send(worker, :emit)
      assert_receive {:reasoning_paused, ^worker}, 1_000
      thinking = Breeze.Test.render!(view)
      assert thinking =~ "Checking the evidence live"
      refute thinking =~ "First answer fragment"
      send(worker, :answer)
      assert_receive {:provider_paused, ^worker}, 1_000

      snapshot = Engine.snapshot(engine)
      [invocation_id] = snapshot.turns[turn_id].invocation_order
      invocation = snapshot.invocations[invocation_id]
      assert invocation.notes == ["Checking the evidence live"]
      assert snapshot.messages[invocation.message_id].body == "First answer fragment"
      assert invocation.status == :running
      screen = Breeze.Test.render!(view)
      assert screen =~ "Checking the evidence live"
      assert screen =~ "First answer fragment"

      case ending do
        :cancel -> :ok = Engine.cancel_turn(turn_id, "Test cancellation", engine)
        other -> send(worker, other)
      end

      outcome = %{finish: :completed, fail: :failed, cancel: :cancelled}
      assert Wait.terminal_turn(engine, turn_id).outcome == Map.fetch!(outcome, ending)
      finished = Engine.snapshot(engine)

      expected =
        if ending == :finish,
          do: "First answer fragment then finished",
          else: "First answer fragment"

      assert finished.messages[invocation.message_id].body == expected
      assert finished.invocations[invocation_id].notes == ["Checking the evidence live"]
    end
  end
end
