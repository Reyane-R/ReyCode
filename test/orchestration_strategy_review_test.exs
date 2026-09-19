defmodule ReyCode.Orchestration.StrategyReviewTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Event, EventStore, Hashing, RuntimeConfig}
  alias ReyCode.EventStore.SQLite.Checkpoint
  alias ReyCode.Memory.Store, as: MemoryStore
  alias ReyCode.Orchestration.{Engine, EventEntries, Projector, StrategicReview, ToolRun, Turn}
  alias ReyCode.Orchestration.Engine.{Loop, Persistence}
  alias ReyCode.Provider.{Response, Runtime, ToolCall}
  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.Agents
  @event_registry __MODULE__.Events
  @agent_supervisor __MODULE__.Workers
  @engine __MODULE__.Engine

  defmodule Catalog do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready, :resolve_continuation] do
      {:reply,
       {:ok,
        %Runtime{
          module: ReyCode.Orchestration.StrategyReviewTest.Provider,
          status: :available,
          config: %{test_pid: test_pid}
        }}, test_pid}
    end
  end

  defmodule Provider do
    @behaviour ReyCode.Provider
    alias ReyCode.Provider.Frame

    @impl true
    def stream(%Runtime{config: %{test_pid: test_pid}}, request, emit) do
      send(test_pid, {:request, self(), request})

      receive do
        {:respond, response} ->
          if response.text != "",
            do: emit.(Frame.text_delta(request.resume_from + 1, response.text))

          {:ok, response}
      after
        10_000 -> {:error, ReyCode.Failure.new(:timeout, "test response deadline")}
      end
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "LIVE PROJECT INSTRUCTIONS")
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    store = start_supervised!({EventStore, name: nil, path: Path.join(dir, "strategy.sqlite3")})
    catalog = start_supervised!({Catalog, self()})
    config = RuntimeConfig.fresh(workspace_roots: [dir], allow_simulator_provider: true)

    opts = [
      name: @engine,
      event_store: store,
      provider_catalog: catalog,
      config: config,
      agent_registry: @agent_registry,
      event_registry: @event_registry,
      agent_supervisor: @agent_supervisor,
      agent_delay_ms: 0
    ]

    start_supervised!({Engine, opts}, restart: :temporary)
    {:ok, session_id} = Engine.create_blank_session("Strategy", dir, @engine)

    {:ok, participant_id} =
      Engine.add_task_participant(session_id, "Reviewer", "Review strategy", @engine)

    :ok =
      Engine.configure_participants(
        session_id,
        ["assistant", participant_id],
        :simulator,
        "test",
        @engine
      )

    {:ok, turn_id} =
      Engine.post_message(session_id, "Build a reliable local review workflow", :direct, @engine)

    assert_receive {:request, worker, _request}, 2_000
    send(worker, {:respond, Response.new(text: "Initial plan recorded")})
    wait_terminal(turn_id)

    %{
      store: store,
      session_id: session_id,
      participant_id: participant_id,
      opts: opts,
      workspace: dir
    }
  end

  test "targeted challenge captures the selected answer and runs tool-free with replayable evidence",
       context do
    before = Engine.snapshot(@engine)
    session = before.sessions[context.session_id]
    message_id = List.first(session.message_order)

    assert {:ok, turn_id} =
             Engine.challenge(
               context.session_id,
               context.participant_id,
               %{"kind" => "answer", "id" => message_id, "question" => "support"},
               @engine
             )

    assert_receive {:request, worker, request}, 2_000
    assert request.tool_names == []
    assert request.system_prompt_mode == :frozen
    packet = Engine.snapshot(@engine).turns[turn_id].strategy_review
    assert packet.focus =~ message_id
    assert [%{"outputs" => [%{"message_id" => ^message_id}]}] = packet.turns
    assert request.system_prompt =~ "Initial plan recorded"

    report =
      Jason.encode!(%{
        summary: "Only the recorded report is available.",
        limitations: "No independent check supports it.",
        findings: []
      })

    send(worker, {:respond, Response.new(text: report)})
    assert wait_terminal(turn_id).outcome == :completed
    assert Projector.replay(EventStore.load(context.store)) == Engine.snapshot(@engine)

    assert {:error, :invalid_challenge_target} =
             Engine.challenge(
               context.session_id,
               context.participant_id,
               %{"kind" => "answer", "id" => "missing", "question" => "support"},
               @engine
             )
  end

  test "decision targets remain selectable behind newer unrelated memories", context do
    {:ok, memory} =
      MemoryStore.record(context.workspace, "decision", "chosen-design", "Use the smaller change")

    for index <- 1..101,
        do: MemoryStore.record(context.workspace, "fact", "fact-#{index}", "unrelated")

    assert {:ok, turn_id} =
             Engine.challenge(
               context.session_id,
               context.participant_id,
               %{"kind" => "decision", "id" => memory.id, "question" => "assumptions"},
               @engine
             )

    assert_receive {:request, worker, request}, 2_000
    assert request.tool_names == []
    packet = Engine.snapshot(@engine).turns[turn_id].strategy_review
    assert [%{"memory_id" => id}] = packet.memory
    assert id == memory.id

    send(
      worker,
      {:respond,
       Response.new(
         text:
           Jason.encode!(%{
             summary: "A recorded decision",
             limitations: "No supporting tools",
             findings: []
           })
       )}
    )

    assert wait_terminal(turn_id).outcome == :completed
  end

  test "ordinary delegation retains live context and instructions", context do
    {:ok, turn_id} =
      Engine.delegate_task(context.session_id, context.participant_id, "Ordinary advice", @engine)

    assert_receive {:request, worker, request}, 2_000
    assert request.system_prompt =~ "LIVE PROJECT INSTRUCTIONS"
    assert Enum.any?(request.messages, &(&1.content == "Ordinary advice"))
    assert request.tool_names == nil
    assert Engine.snapshot(@engine).turns[turn_id].strategy_review == nil
    send(worker, {:respond, Response.new(text: "Ordinary unstructured answer")})
    assert wait_terminal(turn_id).outcome == :completed
  end

  test "review uses only its packet, denies every tool family, and rejects invalid output",
       context do
    {:ok, turn_id} =
      Engine.advise_strategy(
        context.session_id,
        context.participant_id,
        "Check direction",
        @engine
      )

    assert_receive {:request, worker, request}, 2_000
    packet = Engine.snapshot(@engine).turns[turn_id].strategy_review
    assert request.system_prompt == StrategicReview.prompt(packet)
    assert request.system_prompt_mode == :frozen
    assert request.messages == []
    assert request.tool_names == []
    refute request.system_prompt =~ "LIVE PROJECT INSTRUCTIONS"

    assert {:error, :strategy_review_frozen} =
             Engine.steer_turn(turn_id, "Change the packet", @engine)

    tools =
      ~w(read write bash memory spawn_task spawn_tasks send_peer ask_user update_plan unknown)

    calls = Enum.map(tools, &ToolCall.new("call-#{&1}", &1, %{}))
    send(worker, {:respond, Response.new(tool_calls: calls)})
    assert_receive {:request, worker, next_request}, 2_000
    [assistant | results] = next_request.messages
    assert assistant.role == :assistant
    assert Enum.map(assistant.tool_calls, & &1.tool) == tools
    assert length(results) == length(tools)

    assert Enum.all?(
             results,
             &(&1.role == :tool and &1.content =~ "strategy_review_tools_forbidden")
           )

    assert next_request.system_prompt == request.system_prompt
    snapshot = Engine.snapshot(@engine)
    invocation = snapshot.invocations[request.invocation_id]
    assert length(invocation.tool_run_order) == length(tools)

    assert Enum.all?(invocation.tool_runs, fn {_id, run} ->
             run.authorization == :denied and run.status == :failed and
               run.error["error"] == "strategy_review_tools_forbidden"
           end)

    assert map_size(snapshot.invocations) == 2
    assert invocation.coordination.pending_question == nil
    assert invocation.project_instructions.content == ""
    assert invocation.project_instructions.sources == []
    assert invocation.project_instructions.digest == nil

    send(worker, {:respond, Response.new(text: "Not a strategic report")})
    assert wait_terminal(turn_id).outcome == :failed
    failed = Engine.snapshot(@engine)
    assert failed.invocations[request.invocation_id].error.category == :invalid_strategic_output
    assert Projector.replay(EventStore.load(context.store)) == failed
  end

  test "retry and checkpoint recovery preserve the packet despite changed memory and history",
       context do
    {:ok, _memory} = MemoryStore.record(context.workspace, "decision", "scope", "Original scope")

    {:ok, turn_id} =
      Engine.advise_strategy(context.session_id, context.participant_id, "Scope", @engine)

    assert_receive {:request, worker, request}, 2_000
    packet = Engine.snapshot(@engine).turns[turn_id].strategy_review
    send(worker, {:respond, Response.new(text: "Invalid report")})
    assert wait_terminal(turn_id).outcome == :failed

    {:ok, _memory} = MemoryStore.record(context.workspace, "decision", "scope", "NEW MEMORY")
    {:ok, ordinary} = Engine.post_message(context.session_id, "NEW HISTORY", :direct, @engine)
    assert_receive {:request, worker, _ordinary_request}, 2_000
    send(worker, {:respond, Response.new(text: "New plan")})
    wait_terminal(ordinary)
    File.write!(Path.join(context.workspace, "AGENTS.md"), "NEW PROJECT INSTRUCTIONS")

    {:ok, retry_id} = Engine.retry_turn(turn_id, @engine)
    assert_receive {:request, _worker, retry_request}, 2_000
    snapshot = Engine.snapshot(@engine)
    assert snapshot.turns[retry_id].strategy_review == packet
    assert snapshot.turns[retry_id].retry_of_turn_id == turn_id
    assert retry_request.system_prompt == request.system_prompt
    assert retry_request.messages == []
    assert :ok = EventStore.checkpoint(snapshot, context.store)
    stop_supervised!(Engine)
    start_supervised!({Engine, context.opts}, restart: :temporary)
    assert_receive {:request, worker, recovered_request}, 2_000
    assert recovered_request.invocation_id == retry_request.invocation_id
    assert recovered_request.system_prompt == request.system_prompt
    assert recovered_request.messages == []
    assert recovered_request.tool_names == []
    assert Engine.snapshot(@engine).turns[retry_id].strategy_review == packet
    send(worker, {:respond, Response.new(text: "Still invalid")})
    assert wait_terminal(retry_id).outcome == :failed
    assert Projector.replay(EventStore.load(context.store)) == Engine.snapshot(@engine)
  end

  test "durable malformed packets are rejected rather than restored as ordinary turns", context do
    {:ok, turn_id} =
      Engine.advise_strategy(context.session_id, context.participant_id, "Scope", @engine)

    assert_receive {:request, _worker, _request}, 2_000
    snapshot = Engine.snapshot(@engine)
    turn = snapshot.turns[turn_id]
    assert_raise ArgumentError, fn -> Turn.from_map(%{turn | strategy_review: %{}}) end

    [{_type, _data, _metadata}, {:turn_queued, data, metadata}] =
      EventEntries.queue_turn(turn, "Scope", "message", snapshot.sequence)

    assert_raise ArgumentError, fn ->
      Event.new(
        snapshot.sequence + 1,
        :turn_queued,
        Map.put(data, "strategy_review", %{}),
        metadata
      )
    end

    malformed = put_in(snapshot.turns[turn_id].strategy_review, %{})
    encoded = malformed |> Checkpoint.encode_term() |> Jason.encode!()

    assert {:error, :invalid_checkpoint} =
             Checkpoint.decode(
               encoded,
               Checkpoint.projection_version(),
               snapshot.sequence,
               Hashing.sha256_hex(encoded),
               byte_size(encoded)
             )

    assert :ok = Engine.cancel_turn(turn_id, "test finished", @engine)
  end

  test "start guard rejects even an already-ready durable tool run", context do
    {:ok, turn_id} =
      Engine.advise_strategy(context.session_id, context.participant_id, "Scope", @engine)

    assert_receive {:request, _worker, request}, 2_000
    state = :sys.get_state(@engine)
    stop_supervised!(Engine)
    invocation = state.projection.invocations[request.invocation_id]

    run = %ToolRun{
      id: "ready-run",
      tool_call_id: "ready-call",
      round_index: 0,
      tool: "bash",
      arguments: %{"command" => "touch forbidden"},
      workspace: context.workspace,
      workspace_roots: [context.workspace],
      authorization: :allow
    }

    state =
      Persistence.append_and_apply!(state, [EventEntries.tool_run_requested(invocation, run)])

    assert {:reply, {:error, :strategy_review_tools_forbidden}, next} =
             Loop.tool_run_started(state, invocation.id, run.id)

    assert next.projection.invocations[invocation.id].tool_runs[run.id].status == :failed
    refute File.exists?(Path.join(context.workspace, "forbidden"))
    assert next.projection.turns[turn_id].strategy_review != nil

    pending = %{run | id: "pending-run", tool_call_id: "pending-call", authorization: :ask}

    next =
      Persistence.append_and_apply!(next, [EventEntries.tool_run_requested(invocation, pending)])

    assert {:reply, {:error, :strategy_review_tools_forbidden}, unchanged} =
             Loop.resolve_tool_run(next, invocation.id, pending.id, :approve)

    assert unchanged == next

    assert unchanged.projection.invocations[invocation.id].tool_runs[pending.id].status ==
             :awaiting_approval
  end

  test "queued capture stays frozen and a validated report completes successfully", context do
    {:ok, _memory} = MemoryStore.record(context.workspace, "decision", "queued", "Before capture")

    {:ok, preceding_id} =
      Engine.delegate_task(context.session_id, context.participant_id, "Preceding task", @engine)

    assert_receive {:request, preceding_worker, _request}, 2_000

    {:ok, turn_id} =
      Engine.advise_strategy(context.session_id, context.participant_id, "Queued review", @engine)

    queued = Engine.snapshot(@engine).turns[turn_id]
    assert queued.status == :queued
    refute Enum.any?(queued.strategy_review.turns, &(&1["turn_id"] == preceding_id))
    {:ok, _memory} = MemoryStore.record(context.workspace, "decision", "queued", "After capture")
    send(preceding_worker, {:respond, Response.new(text: "Completed after capture")})
    assert wait_terminal(preceding_id).outcome == :completed
    assert_receive {:request, worker, request}, 2_000
    assert request.system_prompt == StrategicReview.prompt(queued.strategy_review)
    assert request.messages == []
    assert Engine.snapshot(@engine).turns[turn_id].strategy_review == queued.strategy_review

    text =
      Jason.encode!(%{
        summary: "Evidence is insufficient for a pattern.",
        limitations: "Frozen bounded evidence only.",
        findings: []
      })

    assert {:ok, ^text} = StrategicReview.validate_output(queued.strategy_review, text)
    send(worker, {:respond, Response.new(text: text)})
    assert wait_terminal(turn_id).outcome == :completed
    snapshot = Engine.snapshot(@engine)
    invocation = snapshot.invocations[request.invocation_id]
    assert invocation.status == :completed
    assert snapshot.messages[invocation.message_id].body == text
    assert Projector.replay(EventStore.load(context.store)) == snapshot
  end

  test "event and restored projection bind packets to the owning session, workspace and cutoff",
       context do
    {:ok, turn_id} =
      Engine.advise_strategy(context.session_id, context.participant_id, "Scope", @engine)

    assert_receive {:request, _worker, _request}, 2_000
    snapshot = Engine.snapshot(@engine)
    turn = snapshot.turns[turn_id]
    packet = turn.strategy_review

    [_message, {:turn_queued, data, metadata}] =
      EventEntries.queue_turn(turn, "Scope", "message", turn.context_through_sequence)

    for invalid <- [
          Map.put(data, "room_id", "another-session"),
          Map.put(data, "context_through_sequence", packet.projection_sequence - 1)
        ] do
      assert_raise ArgumentError, fn ->
        Event.new(snapshot.sequence + 1, :turn_queued, invalid, metadata)
      end
    end

    wrong_workspace = %{packet | workspace: "/another-workspace"}

    event =
      Event.new(
        snapshot.sequence + 1,
        :turn_queued,
        Map.put(data, "strategy_review", StrategicReview.to_wire(wrong_workspace)),
        metadata
      )

    assert_raise ArgumentError, fn -> Projector.apply(event, snapshot) end
    # Projector also checks bindings when callers supply an already-decoded Event.
    assert_raise ArgumentError, fn ->
      Projector.apply(%{event | data: Map.put(data, "room_id", "another-session")}, snapshot)
    end

    for invalid <- [
          put_in(snapshot.turns[turn_id].strategy_review, wrong_workspace),
          put_in(snapshot.turns[turn_id].strategy_review, %{
            packet
            | session_id: "another-session"
          }),
          put_in(
            snapshot.turns[turn_id].context_through_sequence,
            packet.projection_sequence - 1
          ),
          put_in(snapshot.sessions[turn.session_id].id, "another-session"),
          %{snapshot | sessions: Map.delete(snapshot.sessions, turn.session_id)}
        ] do
      assert_raise ArgumentError, fn -> Projector.replay([], invalid) end
      encoded = invalid |> Checkpoint.encode_term() |> Jason.encode!()

      assert {:error, :invalid_checkpoint} =
               Checkpoint.decode(
                 encoded,
                 Checkpoint.projection_version(),
                 snapshot.sequence,
                 Hashing.sha256_hex(encoded),
                 byte_size(encoded)
               )
    end

    assert :ok = Engine.cancel_turn(turn_id, "test finished", @engine)
  end

  defp wait_terminal(turn_id), do: Wait.terminal_turn(@engine, turn_id)
end
