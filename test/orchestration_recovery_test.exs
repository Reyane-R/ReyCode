defmodule ReyCode.Orchestration.RecoveryTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}

  alias ReyCode.Orchestration.{
    Engine,
    EventEntries,
    Invocation,
    OperatorQuestion,
    OperatorQuestions,
    Participant,
    Projector,
    Session,
    ToolRun,
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
        config: %{test_pid: test_pid}
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule BlockingProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.Response

    @impl true
    def stream(%Runtime{config: %{test_pid: test_pid}}, request, _emit) do
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
          %Turn{
            id: turn_id,
            session_id: session_id,
            mode: :compare,
            input_kind: :operator
          },
          "Recover this",
          "msg-user",
          2
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

  test "leaves a waiting_operator invocation dormant across recovery" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_operator_wait_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-operator-wait"
    turn_id = "turn-operator-wait"
    invocation_id = "inv-operator-wait"

    builder_participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "build",
      provider: :simulator,
      model: nil,
      kind: :primary
    }

    invocation = %Invocation{
      id: invocation_id,
      session_id: session_id,
      turn_id: turn_id,
      message_id: "msg-operator-wait"
    }

    run = %ToolRun{
      id: "run-operator-wait",
      tool_call_id: "call-operator-wait",
      round_index: 0,
      tool: OperatorQuestions.tool_name(),
      arguments: %{"question" => "Proceed?"},
      workspace: System.tmp_dir!(),
      workspace_roots: [],
      authorization: :allow
    }

    question = %OperatorQuestion{
      id: "question-operator-wait",
      tool_run_id: run.id,
      question: "Proceed with the rollout?",
      options: [%{id: "opt-proceed", label: "Proceed", description: "Continue", preview: ""}],
      recommended_id: "opt-proceed",
      asked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    entries =
      [
        EventEntries.session_created(
          session_id,
          "operator-wait",
          "Operator Wait",
          System.tmp_dir!(),
          primary_participants([{"builder", "simulator"}])
        )
      ] ++
        EventEntries.queue_turn(
          %Turn{id: turn_id, session_id: session_id, mode: :compare, input_kind: :operator},
          "Await my decision",
          "msg-user",
          2
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
          [{invocation_id, invocation.message_id}]
        ) ++
        [
          EventEntries.invocation_started(invocation),
          EventEntries.tool_run_requested(invocation, run),
          EventEntries.tool_run_started(invocation, run),
          EventEntries.operator_question_asked(invocation, question)
        ]

    assert {:ok, _events} = EventStore.append_many(entries, store)
    pre_boot = EventStore.load(store)

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

    snapshot = Engine.snapshot(@engine)
    recovered = snapshot.invocations[invocation_id]

    assert recovered.status == :waiting_operator
    assert recovered.coordination.pending_question.id == question.id
    assert recovered.tool_runs[run.id].status == :running
    assert snapshot.sessions[session_id].active_turn_id == turn_id
    assert Registry.lookup(@agent_registry, invocation_id) == []
    assert EventStore.load(store) == pre_boot
  end

  test "kills a stale queued worker and starts the queued invocation after recovery" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_queued_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-queued-recovery"
    turn_id = "turn-queued-recovery"
    invocation_id = "inv-queued-recovery"

    builder_participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "build",
      provider: :simulator,
      model: nil,
      kind: :primary
    }

    entries =
      [
        EventEntries.session_created(
          session_id,
          "queued-recovery",
          "Queued Recovery",
          System.tmp_dir!(),
          primary_participants([{"builder", "simulator"}])
        )
      ] ++
        EventEntries.queue_turn(
          %Turn{id: turn_id, session_id: session_id, mode: :compare, input_kind: :operator},
          "Recover this queued turn",
          "msg-user",
          2
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
          [{invocation_id, "msg-queued-recovery"}]
        )

    assert {:ok, _events} = EventStore.append_many(entries, store)

    parent = self()

    survivor =
      spawn(fn ->
        Registry.register(@agent_registry, invocation_id, nil)
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

    snapshot = Engine.snapshot(@engine)
    assert snapshot.invocations[invocation_id].status == :completed

    started_count =
      Enum.count(EventStore.load(store), fn event ->
        event.type == :invocation_started and event.data["invocation_id"] == invocation_id
      end)

    assert started_count == 1
  end

  test "restarts a running invocation without a surviving worker when the provider is replayable" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_running_restart_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-running-restart"
    turn_id = "turn-running-restart"
    invocation_id = "inv-running-restart"

    builder_participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "build",
      provider: :simulator,
      model: nil,
      kind: :primary
    }

    entries =
      [
        EventEntries.session_created(
          session_id,
          "running-restart",
          "Running Restart",
          System.tmp_dir!(),
          primary_participants([{"builder", "simulator"}])
        )
      ] ++
        EventEntries.queue_turn(
          %Turn{id: turn_id, session_id: session_id, mode: :compare, input_kind: :operator},
          "Recover this running turn",
          "msg-user",
          2
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
          [{invocation_id, "msg-running-restart"}]
        ) ++
        [
          EventEntries.invocation_started(%Invocation{
            id: invocation_id,
            session_id: session_id,
            turn_id: turn_id,
            message_id: "msg-running-restart"
          })
        ]

    assert {:ok, _events} = EventStore.append_many(entries, store)
    assert Registry.lookup(@agent_registry, invocation_id) == []

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

    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

    snapshot = Engine.snapshot(@engine)
    assert snapshot.invocations[invocation_id].status == :completed

    assert Enum.any?(EventStore.load(store), fn event ->
             event.type == :invocation_completed and
               event.data["invocation_id"] == invocation_id
           end)
  end

  test "fails a running invocation whose surviving worker cannot be replayed" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_live_non_replayable_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-live-non-replayable"
    turn_id = "turn-live-non-replayable"
    invocation_id = "inv-live-non-replayable"

    builder_participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "build",
      provider: :open_code,
      model: nil,
      kind: :primary
    }

    entries =
      [
        EventEntries.session_created(
          session_id,
          "live-non-replayable",
          "Live Non-replayable",
          System.tmp_dir!(),
          primary_participants([{"builder", "open_code"}])
        )
      ] ++
        EventEntries.queue_turn(
          %Turn{id: turn_id, session_id: session_id, mode: :compare, input_kind: :operator},
          "Recover safely",
          "msg-user",
          2
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
          [{invocation_id, "msg-live-non-replayable"}]
        ) ++
        [
          EventEntries.invocation_started(%Invocation{
            id: invocation_id,
            session_id: session_id,
            turn_id: turn_id,
            message_id: "msg-live-non-replayable"
          })
        ]

    assert {:ok, _events} = EventStore.append_many(entries, store)

    parent = self()

    survivor =
      spawn(fn ->
        Registry.register(@agent_registry, invocation_id, nil)
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
    assert Wait.terminal_turn(@engine, turn_id).outcome == :failed

    snapshot = Engine.snapshot(@engine)
    failed = snapshot.invocations[invocation_id]

    assert failed.status == :failed
    assert failed.error.category == :interrupted
    refute failed.error.retryable?
    assert failed.error.message =~ "cannot be replayed safely"
    assert Registry.lookup(@agent_registry, invocation_id) == []
  end

  test "interrupts and fails a running invocation recovered with a started tool run" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_interrupted_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-interrupted"
    turn_id = "turn-interrupted"
    invocation_id = "inv-interrupted"

    builder_participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "build",
      provider: :open_code,
      model: nil,
      kind: :primary
    }

    invocation = %Invocation{
      id: invocation_id,
      session_id: session_id,
      turn_id: turn_id,
      message_id: "msg-interrupted"
    }

    run = %ToolRun{
      id: "run-interrupted",
      tool_call_id: "call-interrupted",
      round_index: 0,
      tool: "bash",
      arguments: %{"command" => "mix test"},
      workspace: System.tmp_dir!(),
      workspace_roots: [],
      authorization: :allow
    }

    entries =
      [
        EventEntries.session_created(
          session_id,
          "interrupted",
          "Interrupted",
          System.tmp_dir!(),
          primary_participants([{"builder", "open_code"}])
        )
      ] ++
        EventEntries.queue_turn(
          %Turn{id: turn_id, session_id: session_id, mode: :compare, input_kind: :operator},
          "Recover this interrupted turn",
          "msg-user",
          2
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
          [{invocation_id, invocation.message_id}]
        ) ++
        [
          EventEntries.invocation_started(invocation),
          EventEntries.tool_run_requested(invocation, run),
          EventEntries.tool_run_started(invocation, run)
        ]

    assert {:ok, _events} = EventStore.append_many(entries, store)

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

    snapshot = Engine.snapshot(@engine)
    failed = snapshot.invocations[invocation_id]

    assert failed.status == :failed
    assert failed.error.category == :interrupted
    refute failed.error.retryable?
    assert failed.error.message =~ "interrupted mid tool run"
    assert failed.tool_runs[run.id].status == :interrupted
    assert Registry.lookup(@agent_registry, invocation_id) == []

    assert Enum.any?(EventStore.load(store), fn event ->
             event.type == :tool_run_interrupted and
               event.data["invocation_id"] == invocation_id and
               event.data["tool_run_id"] == run.id and
               event.data["reason"] == "worker_exit"
           end)
  end

  test "opens the initial invocations of a started turn after recovery" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_initial_invocations_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    session_id = "room-initial-invocations"
    turn_id = "turn-initial-invocations"

    entries =
      [
        EventEntries.session_created(
          session_id,
          "initial-invocations",
          "Initial Invocations",
          System.tmp_dir!(),
          primary_participants([
            {"builder", "simulator"},
            {"critic", "simulator"},
            {"explorer", "simulator"}
          ])
        )
      ] ++
        EventEntries.queue_turn(
          %Turn{id: turn_id, session_id: session_id, mode: :compare, input_kind: :operator},
          "Start me again",
          "msg-user",
          2
        ) ++
        [EventEntries.turn_started(%Turn{id: turn_id, session_id: session_id})]

    assert {:ok, _events} = EventStore.append_many(entries, store)

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

    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

    snapshot = Engine.snapshot(@engine)
    order = snapshot.turns[turn_id].invocation_order
    assert length(order) == 3
    assert Enum.all?(order, &(snapshot.invocations[&1].status == :completed))

    assert Enum.count(EventStore.load(store), &(&1.type == :assistant_message_opened)) == 3
  end

  defp primary_participants(participants) do
    Enum.map(participants, fn {id, provider} ->
      %{
        "id" => id,
        "name" => String.capitalize(id),
        "perspective" => id,
        "provider" => provider,
        "model" => nil,
        "kind" => "primary"
      }
    end)
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
