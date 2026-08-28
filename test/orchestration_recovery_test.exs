defmodule ReyCode.Orchestration.RecoveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}

  alias ReyCode.Orchestration.{
    Engine,
    EventEntries,
    Invocation,
    Participant,
    Projector,
    Session,
    Turn
  }

  alias ReyCode.Provider.{Frame, Runtime}
  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule BlockingCatalog do
    use GenServer

    alias ReyCode.Orchestration.RecoveryTest.BlockingProvider
    alias ReyCode.Provider.Runtime

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid))
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready] do
      runtime = %Runtime{
        module: BlockingProvider,
        status: :available,
        executable: test_pid
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule BlockingProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.Response

    @impl true
    def stream(%Runtime{executable: test_pid}, request, _emit) do
      send(test_pid, {:provider_waiting, request.invocation_id, self()})

      receive do
        :complete -> {:ok, Response.new(text: "")}
      after
        10_000 ->
          {:error,
           %{
             "category" => "test_timeout",
             "message" => "blocking test provider was not released",
             "retryable" => false
           }}
      end
    end
  end

  test "kills a surviving running agent on recovery and restarts its execution" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_midstream_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-midstream"
    turn_id = "turn-midstream"

    builder_participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "builder",
      provider: :simulator,
      model: nil,
      kind: :primary
    }

    entries =
      [
        EventEntries.session_created(
          session_id,
          "midstream",
          "Midstream",
          System.tmp_dir!(),
          participants()
        )
      ] ++
        EventEntries.queue_turn(
          session_id,
          "Recover this",
          :compare,
          turn_id,
          "msg-user",
          2,
          :operator,
          nil
        ) ++
        [EventEntries.turn_started(%Turn{id: turn_id, session_id: session_id})] ++
        EventEntries.open_invocations(
          %Session{id: session_id},
          %Turn{id: turn_id, session_id: session_id},
          [
            %{
              participant_id: builder_participant.id,
              participant: builder_participant,
              phase_index: 0,
              label: "independent response",
              system_prompt: "Respond independently",
              attempt: 1
            }
          ],
          [{"inv-builder", "msg-builder"}]
        ) ++
        [
          EventEntries.invocation_started(%Invocation{
            id: "inv-builder",
            session_id: session_id,
            turn_id: turn_id,
            message_id: "msg-builder"
          })
        ]

    assert {:ok, _events} = EventStore.append_many(entries, store)

    parent = self()

    survivor =
      spawn(fn ->
        Registry.register(@agent_registry, "inv-builder", nil)
        send(parent, :survivor_registered)
        Process.sleep(:infinity)
      end)

    survivor_ref = Process.monitor(survivor)
    assert_receive :survivor_registered, 1_000

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: ReyCode.Provider.Catalog,
       agent_delay_ms: 0}
    )

    assert_receive {:DOWN, ^survivor_ref, :process, ^survivor, :killed}, 5_000

    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed
    assert Engine.snapshot(@engine).turns[turn_id].invocation_order == ["inv-builder"]
  end

  test "accepted frames are durable before invocation completion" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_ghost_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({BlockingCatalog, test_pid: self()})

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: catalog,
       config: RuntimeConfig.fresh(global_concurrency: 3, workspace_concurrency: 3)}
    )

    assert {:ok, session_id} =
             Engine.create_blank_session("Ghost Room", System.tmp_dir!(), @engine)

    assert {:ok, turn_id} = Engine.post_message(session_id, "Start", :compare, @engine)

    Wait.projection(@engine, fn projection ->
      turn = projection.turns[turn_id]

      if turn &&
           Enum.all?(turn.invocation_order, &(projection.invocations[&1].status == :running)),
         do: projection
    end)

    snapshot = Engine.snapshot(@engine)
    [builder_id | _] = snapshot.turns[turn_id].invocation_order

    provider_processes =
      Map.new(snapshot.turns[turn_id].invocation_order, fn invocation_id ->
        assert_receive {:provider_waiting, ^invocation_id, provider_pid}, 1_000
        {invocation_id, provider_pid}
      end)

    sequence = snapshot.invocations[builder_id].last_frame_sequence + 1

    assert :ok =
             Engine.Client.record_frame(@engine, builder_id, Frame.text_delta(sequence, "ghost "))

    assert Enum.any?(EventStore.load(store), fn event ->
             event.type == :provider_frame_recorded and
               event.data["invocation_id"] == builder_id and
               event.data["data"] == %{"text" => "ghost "}
           end)

    Enum.each(provider_processes, fn {_invocation_id, provider_pid} ->
      send(provider_pid, :complete)
    end)

    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

    live = Engine.snapshot(@engine)
    replayed = Projector.replay(EventStore.load(store))

    assert live == replayed
  end

  test "fails a non-replayable interrupted invocation as non-retryable" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_non_replayable_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-non-replayable"
    turn_id = "turn-non-replayable"
    invocation_id = "inv-non-replayable"
    message_id = "msg-non-replayable"

    participant = %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "build",
      "provider" => "open_code",
      "model" => nil
    }

    assert {:ok, _events} =
             EventStore.append_many(
               [
                 {
                   :room_created,
                   %{
                     "room_id" => session_id,
                     "slug" => "non-replayable",
                     "title" => "Non-replayable",
                     "workspace" => System.tmp_dir!(),
                     "participants" => [participant]
                   },
                   metadata(:room, session_id, session_id, turn_id)
                 },
                 {
                   :message_posted,
                   %{
                     "message_id" => "msg-user-non-replayable",
                     "room_id" => session_id,
                     "turn_id" => turn_id,
                     "author_name" => "You",
                     "body" => "Recover safely"
                   },
                   metadata(:room, session_id, session_id, turn_id)
                 },
                 {
                   :turn_queued,
                   %{
                     "turn_id" => turn_id,
                     "room_id" => session_id,
                     "user_message_id" => "msg-user-non-replayable",
                     "mode" => "compare",
                     "context_through_sequence" => 2
                   },
                   metadata(:turn, turn_id, session_id, turn_id)
                 },
                 {
                   :turn_started,
                   %{"turn_id" => turn_id, "room_id" => session_id},
                   metadata(:turn, turn_id, session_id, turn_id)
                 },
                 {
                   :assistant_message_opened,
                   %{
                     "invocation_id" => invocation_id,
                     "message_id" => message_id,
                     "turn_id" => turn_id,
                     "room_id" => session_id,
                     "participant" => participant,
                     "stage" => 0,
                     "label" => "independent response",
                     "system_prompt" => "Respond independently",
                     "attempt" => 1
                   },
                   metadata(:invocation, invocation_id, session_id, turn_id)
                 },
                 {
                   :invocation_started,
                   %{
                     "invocation_id" => invocation_id,
                     "message_id" => message_id,
                     "turn_id" => turn_id,
                     "room_id" => session_id
                   },
                   metadata(:invocation, invocation_id, session_id, turn_id)
                 }
               ],
               store
             )

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: ReyCode.Provider.Catalog,
       agent_delay_ms: 0}
    )

    assert Wait.terminal_turn(@engine, turn_id).outcome == :failed

    error = Engine.snapshot(@engine).invocations[invocation_id].error
    assert error.category == :interrupted
    refute error.retryable?
    assert error.message =~ "cannot be replayed safely"
  end

  defp participants do
    Enum.map([{"builder", "Builder"}, {"critic", "Critic"}, {"explorer", "Explorer"}], fn {id,
                                                                                           name} ->
      %{
        "id" => id,
        "name" => name,
        "perspective" => id,
        "provider" => "simulator",
        "model" => nil
      }
    end)
  end

  defp metadata(type, aggregate_id, session_id, correlation_id) do
    [
      aggregate_type: type,
      aggregate_id: aggregate_id,
      room_id: session_id,
      correlation_id: correlation_id
    ]
  end
end
