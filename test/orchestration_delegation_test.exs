defmodule ReyCode.Orchestration.DelegationTest do
  @moduledoc """
  Engine-level integration for agent-initiated delegation (`spawn_task`).

  A scripted catalog resolves every provider request to a scripted provider.
  The parent's user message carries a directive ("delegate: <agent> :: <task>")
  that the script turns into a `spawn_task` call, so each scenario — happy
  path, blocked child (restart and cancel), nested denial, and the fail-closed
  addressing matrix — is driven by plain message text.
  """

  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}

  alias ReyCode.Orchestration.Projector

  alias ReyCode.Orchestration.{
    Delegation,
    Engine,
    Invocation,
    Participant,
    Projection,
    Room,
    ToolRun,
    Turn
  }

  alias ReyCode.Provider.{Response, Runtime, ToolCall}

  alias ReyCode.Test.Wait
  alias ReyCode.TUI.Activity

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine
  @task_agent "Luna"

  defmodule ScriptedCatalog do
    use GenServer

    alias ReyCode.Orchestration.DelegationTest.ScriptedProvider
    alias ReyCode.Provider.Runtime

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid))

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready] do
      runtime = %Runtime{
        module: ScriptedProvider,
        status: :available,
        executable: test_pid
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule ScriptedProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.{Frame, Response, ToolCall}

    @impl true
    def stream(%Runtime{executable: test_pid}, request, emit) do
      case {request.label, request.round_index} do
        {"assistant response", round} when round in [0, 1, 2] ->
          parent_round(test_pid, request, round)

        {"delegated task", round} when round in [0, 1] ->
          child_round(test_pid, request, emit, round)

        {_label, overrun} ->
          overrun(test_pid, overrun)
      end
    end

    # The user message carries "delegate: <agent> :: <brief>"; the script turns
    # it into the spawn_task call verbatim. Brief "twice" delegates again at
    # round one; brief "block" parks the child on a message from the test;
    # brief "nest target X" has the child attempt its own spawn_task.
    defp parent_round(test_pid, request, round) do
      send(test_pid, {:parent_round, round})
      directive = parent_directive(request)

      cond do
        is_nil(directive) ->
          finish_parent(test_pid, request)

        round == 0 or (round == 1 and spawn_twice?(directive)) ->
          {:ok, Response.new(tool_calls: [spawn_call(request.round_index, directive)])}

        true ->
          finish_parent(test_pid, request)
      end
    end

    defp spawn_twice?({_agent, brief}),
      do: brief == "twice" or String.starts_with?(brief, "recovery twice")

    defp spawn_call(call_index, {agent, brief}) do
      ToolCall.new("call-spawn-#{call_index}", "spawn_task", %{
        "agent" => agent,
        "brief" => brief
      })
    end

    defp finish_parent(test_pid, request) do
      send(test_pid, {:tool_result_in_conversation, latest_tool_content(request)})

      {:ok,
       Response.new(
         text: "parent done",
         usage: %{"prompt_tokens" => 4, "completion_tokens" => 2}
       )}
    end

    defp parent_directive(request) do
      Enum.find_value(request.messages, fn
        %{role: :user, content: content} -> parse_directive(content)
        _other -> nil
      end)
    end

    defp parse_directive("delegate: " <> rest) do
      case String.split(rest, " :: ", parts: 2) do
        [agent, brief] -> {String.trim(agent), String.trim(brief)}
        _single -> nil
      end
    end

    defp parse_directive(_body), do: nil

    defp child_round(test_pid, request, emit, round) do
      send(test_pid, {:child_round, round})
      send(test_pid, {:child_user_messages, child_user_messages(request)})
      dispatch_child(test_pid, request, emit, round, child_brief(request))
    end

    defp child_user_messages(request) do
      Enum.flat_map(request.messages, fn
        %{role: :user, content: content} -> [content]
        _other -> []
      end)
    end

    defp dispatch_child(test_pid, request, emit, round, brief) do
      case child_scenario(brief, round) do
        :recovery ->
          recovery_child(test_pid, request, emit)

        :block ->
          block_child(test_pid, request, emit)

        :fail ->
          {:error, ReyCode.Failure.new(:internal, "child exploded")}

        :nested ->
          nested_spawn(brief)

        :finish ->
          report_nested_denial(test_pid, request, brief, round)
          finish_child(emit, request)
      end
    end

    defp child_scenario(brief, round) do
      brief = brief || ""

      cond do
        String.contains?(brief, "recovery twice") -> :recovery
        String.contains?(brief, "block") -> :block
        String.contains?(brief, "fail child") -> :fail
        nested?(brief) and round == 0 -> :nested
        true -> :finish
      end
    end

    defp nested?(brief), do: String.contains?(brief || "", "nest")

    defp nested_spawn(brief) do
      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("call-nested", "spawn_task", %{
             "agent" => nested_target(brief),
             "brief" => "nested delegation attempt"
           })
         ]
       )}
    end

    defp report_nested_denial(test_pid, request, brief, round) do
      if round != 0 and nested?(brief) do
        send(test_pid, {:child_tool_denied, latest_tool_content(request)})
      end
    end

    defp nested_target(brief) do
      case Regex.run(~r/target (\S+)/, brief || "") do
        [_match, target] -> target
        _none -> "Luna"
      end
    end

    defp recovery_child(test_pid, request, emit) do
      send(test_pid, {:recovery_child_waiting, request.invocation_id, self()})

      receive do
        :child_complete -> finish_child(emit, request)
      after
        5_000 ->
          {:error, %{category: "internal", message: "recovery child timed out", retryable: false}}
      end
    end

    defp block_child(test_pid, request, emit) do
      send(test_pid, {:child_waiting, request.invocation_id, self()})

      receive do
        :child_complete ->
          send(test_pid, {:child_released, request.invocation_id, request.round_index})
          finish_child(emit, request)
      after
        5_000 ->
          {:error, %{category: "internal", message: "blocked child timed out", retryable: false}}
      end
    end

    # The child's brief rides in its system prompt after the delegated-task
    # marker written by Delegation.child_system_prompt/2.
    defp child_brief(request) do
      case request.system_prompt do
        nil -> nil
        prompt -> List.last(String.split(prompt, "Delegated task:\n", parts: 2))
      end
    end

    defp finish_child(emit, request) do
      # The report body reaches the projection through streamed text frames,
      # exactly as a real provider delivers assistant output.
      :ok = emit.(Frame.text_delta(request.resume_from + 1, "child report"))

      {:ok,
       Response.new(
         text: "child report",
         usage: %{"prompt_tokens" => 3, "completion_tokens" => 5}
       )}
    end

    defp latest_tool_content(request) do
      Enum.find_value(Enum.reverse(request.messages), "", fn
        %{role: :tool, content: content} -> content
        _other -> nil
      end)
    end

    defp overrun(test_pid, round) do
      send(test_pid, {:unexpected_round, round})
      {:error, %{category: "internal", message: "scripted loop overrun", retryable: false}}
    end
  end

  describe "spawn_task delegation lifecycle" do
    test "suspends the parent durably while the child runs and resumes with its report" do
      stack = start_stack()
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(
                 room_id,
                 "delegate: #{@task_agent} :: run the tests",
                 :direct,
                 @engine
               )

      # Ordering proves zero parent provider rounds during the child window:
      # parent round zero spawns, only the child streams, then the parent
      # resumes and cites the recorded result.
      assert_receive {:parent_round, 0}, 5_000
      assert_receive {:child_user_messages, []}, 5_000
      assert_receive {:child_round, 0}, 5_000
      assert_receive {:tool_result_in_conversation, tool_result}, 5_000
      assert tool_result =~ "child report"
      assert_receive {:parent_round, 1}, 5_000
      refute_received {:unexpected_round, _round}

      assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

      snapshot = Engine.snapshot(@engine)
      assert [parent_id, child_id] = snapshot.turns[turn_id].invocation_order

      parent = snapshot.invocations[parent_id]

      assert [%{status: :completed, result: result}] =
               parent.tool_run_order |> Enum.map(&parent.tool_runs[&1])

      assert result["output"] == "child report"
      assert result["truncated"] == false
      assert result["metadata"]["usage"] == %{"prompt_tokens" => 3, "completion_tokens" => 5}

      assert hd(parent.tool_run_order |> Enum.map(&parent.tool_runs[&1])).child_invocation_id ==
               child_id

      child = snapshot.invocations[child_id]
      assert child.status == :completed
      assert child.delegation_depth == 1
      assert child.delegated_from_invocation_id == parent_id
      assert child.delegated_from_tool_run_id == hd(parent.tool_run_order)
      assert is_map(child.usage) and child.usage != %{}
    end

    test "failed child remains a failed tool result for the resumed parent" do
      stack = start_stack()
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(
                 room_id,
                 "delegate: #{@task_agent} :: fail child",
                 :direct,
                 @engine
               )

      assert Wait.terminal_turn(@engine, turn_id).outcome == :partial
      assert_receive {:tool_result_in_conversation, tool_result}, 5_000
      assert tool_result =~ ~s("ok":false)
      assert tool_result =~ "child exploded"

      snapshot = Engine.snapshot(@engine)
      assert [parent_id, child_id] = snapshot.turns[turn_id].invocation_order
      assert snapshot.invocations[child_id].status == :failed

      parent = snapshot.invocations[parent_id]
      assert [run] = Enum.map(parent.tool_run_order, &parent.tool_runs[&1])
      assert run.status == :failed
      assert run.error["error"] =~ "child exploded"
    end
  end

  describe "recovery" do
    test "restart mid-child resumes the child first and completes both sides exactly once" do
      stack = start_stack()
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(
                 room_id,
                 "delegate: #{@task_agent} :: block on purpose",
                 :direct,
                 @engine
               )

      assert_receive {:child_waiting, child_inv, first_child_pid}, 5_000
      assert_receive {:child_round, 0}, 5_000
      parent_id = suspended_parent(turn_id)

      # Simulate an engine restart; workers survive under their own supervisor.
      :ok = GenServer.stop(@engine)
      start_engine(stack.store, stack.config, stack.catalog)

      # Recovery kills the surviving child worker and replays it; the blocked
      # script waits again under the new worker before being released.
      assert_receive {:child_waiting, ^child_inv, new_child_pid}, 5_000
      refute new_child_pid == first_child_pid

      recovered = Engine.snapshot(@engine)
      activity = Activity.present(room_id, recovered, %{}, System.system_time(:millisecond))
      assert Activity.active?(activity)
      assert activity.header.label == "Delegating"

      send(new_child_pid, :child_complete)

      assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

      events = EventStore.load(stack.store)
      assert Enum.count(events, &(&1.type == :invocation_completed)) == 2
      assert Projector.replay(events) == Engine.snapshot(@engine)

      snapshot = Engine.snapshot(@engine)
      assert Map.has_key?(snapshot.invocations, parent_id)
      assert Map.has_key?(snapshot.invocations, child_inv)
    end

    test "recovery resumes the newest running child after an earlier delegation completed" do
      stack = start_stack(delegation_max_children_per_invocation: 2)
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(
                 room_id,
                 "delegate: #{@task_agent} :: recovery twice",
                 :direct,
                 @engine
               )

      assert_receive {:recovery_child_waiting, first_child_id, first_child_pid}, 5_000
      send(first_child_pid, :child_complete)
      assert_receive {:parent_round, 1}, 5_000
      assert_receive {:recovery_child_waiting, second_child_id, old_second_pid}, 5_000
      refute second_child_id == first_child_id
      _parent_id = suspended_parent(turn_id)

      :ok = GenServer.stop(@engine)
      start_engine(stack.store, stack.config, stack.catalog)

      assert_receive {:recovery_child_waiting, ^second_child_id, new_second_pid}, 5_000
      refute new_second_pid == old_second_pid
      send(new_second_pid, :child_complete)

      assert Wait.terminal_turn(@engine, turn_id).outcome == :completed
      snapshot = Engine.snapshot(@engine)

      assert [parent_id, ^first_child_id, ^second_child_id] =
               snapshot.turns[turn_id].invocation_order

      parent = snapshot.invocations[parent_id]

      assert Enum.map(parent.tool_run_order, &parent.tool_runs[&1].status) == [
               :completed,
               :completed
             ]
    end

    test "cancelling mid-child fails the pending run and terminates the child exactly once" do
      stack = start_stack()
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(
                 room_id,
                 "delegate: #{@task_agent} :: block on purpose",
                 :direct,
                 @engine
               )

      assert_receive {:child_waiting, child_inv, child_pid}, 5_000
      assert_receive {:child_round, 0}, 5_000
      parent_id = suspended_parent(turn_id)

      assert :ok = Engine.cancel_turn(turn_id, "owner changed course", @engine)

      assert Wait.terminal_turn(@engine, turn_id).status == :terminal

      send(child_pid, :child_complete)
      refute_receive {:child_round, _round}, 200

      snapshot = Engine.snapshot(@engine)
      assert snapshot.invocations[parent_id].status == :cancelled
      assert snapshot.invocations[child_inv].status == :cancelled

      runs = snapshot.invocations[parent_id].tool_runs |> Map.values()
      assert [%{status: :failed, error: %{"error" => "turn_cancelled"}}] = runs

      events = EventStore.load(stack.store)
      refute Enum.any?(events, &(&1.type == :invocation_completed))
      assert Enum.count(events, &(&1.type == :invocation_cancelled)) == 2

      activity = Activity.present(room_id, snapshot, %{}, System.system_time(:millisecond))
      refute Activity.active?(activity)
      assert activity.header.outcome == :cancelled
    end
  end

  describe "fail-closed addressing" do
    test "unknown agent yields a failed tool run without spawning a child" do
      {turn_id} = run_delegation_scenario("delegate: Nobody :: impossible task")
      refute_received {:child_round, _round}

      snapshot = Engine.snapshot(@engine)
      assert length(snapshot.turns[turn_id].invocation_order) == 1

      [only_id] = snapshot.turns[turn_id].invocation_order
      invocation = snapshot.invocations[only_id]

      assert [%{status: :failed, error: %{"error" => "unknown_agent"}}] =
               invocation.tool_run_order |> Enum.map(&invocation.tool_runs[&1])

      assert Wait.terminal_turn(@engine, turn_id).outcome == :completed
    end

    test "primary-addressed target is rejected as primary_target" do
      {turn_id} = run_delegation_scenario("delegate: Assistant :: primary work")

      snapshot = Engine.snapshot(@engine)
      [only_id] = snapshot.turns[turn_id].invocation_order
      invocation = snapshot.invocations[only_id]

      assert [%{status: :failed, error: %{"error" => "primary_target"}}] =
               invocation.tool_run_order |> Enum.map(&invocation.tool_runs[&1])

      assert length(snapshot.turns[turn_id].invocation_order) == 1
    end

    test "a child calling spawn_task gets a deterministic depth denial" do
      {turn_id} = run_delegation_scenario("delegate: #{@task_agent} :: nest target Luna")

      assert_receive {:child_round, 0}, 5_000
      assert_receive {:child_tool_denied, denied_result}, 5_000
      assert denied_result =~ "delegation_depth_exceeded"
      assert_receive {:tool_result_in_conversation, parent_tool_result}, 5_000
      assert parent_tool_result =~ "child report"

      assert Wait.terminal_turn(@engine, turn_id).outcome == :completed
      snapshot = Engine.snapshot(@engine)
      assert length(snapshot.turns[turn_id].invocation_order) == 2
    end

    test "oversized brief is denied by the byte cap" do
      stack = start_stack(delegation_brief_max_bytes: 16)
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(
                 room_id,
                 "delegate: #{@task_agent} :: a brief far beyond sixteen bytes",
                 :direct,
                 @engine
               )

      Wait.terminal_turn(@engine, turn_id)

      snapshot = Engine.snapshot(@engine)
      assert length(snapshot.turns[turn_id].invocation_order) == 1

      [only_id] = snapshot.turns[turn_id].invocation_order
      invocation = snapshot.invocations[only_id]

      assert [%{status: :failed, error: %{"error" => "brief_too_large"}}] =
               invocation.tool_run_order |> Enum.map(&invocation.tool_runs[&1])
    end

    test "child cap denies further delegations deterministically" do
      stack = start_stack(delegation_max_children_per_invocation: 1)
      room_id = new_room(stack)
      configure_room(room_id)

      assert {:ok, turn_id} =
               Engine.post_message(room_id, "delegate: #{@task_agent} :: twice", :direct, @engine)

      assert_receive {:parent_round, 0}, 5_000
      assert_receive {:child_round, 0}, 5_000
      assert_receive {:parent_round, 1}, 5_000
      assert_receive {:parent_round, 2}, 5_000

      assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

      snapshot = Engine.snapshot(@engine)
      assert [parent_id, _child_id] = snapshot.turns[turn_id].invocation_order
      parent = snapshot.invocations[parent_id]

      runs = parent.tool_run_order |> Enum.map(&parent.tool_runs[&1])
      assert Enum.map(runs, & &1.status) == [:completed, :failed]
      assert runs |> List.last() |> then(& &1.error["error"]) == "child_cap_exceeded"
    end
  end

  describe "delegation policy" do
    test "rejects ambiguous exact names" do
      {invocation, projection} = policy_fixture(:direct, duplicate_name?: true)

      assert {:error, :ambiguous_agent} =
               Delegation.authorize(
                 invocation,
                 %{"agent" => "Luna", "brief" => "task"},
                 projection,
                 %{max_children: 1, brief_max_bytes: 100}
               )
    end

    test "rejects squad children before finalization" do
      {invocation, projection} = policy_fixture(:squad)

      assert {:error, :delegation_unsupported_in_squad} =
               Delegation.authorize(
                 invocation,
                 %{"agent" => "Luna", "brief" => "task"},
                 projection,
                 %{max_children: 1, brief_max_bytes: 100}
               )
    end

    test "rejected calls do not consume the spawned-child cap" do
      denied = %ToolRun{
        id: "denied",
        tool: "spawn_task",
        status: :failed,
        child_invocation_id: nil
      }

      {invocation, projection} =
        policy_fixture(:direct,
          tool_runs: %{"denied" => denied},
          tool_run_order: ["denied"]
        )

      assert {:ok, %Delegation.Plan{participant: %Participant{name: "Luna"}}} =
               Delegation.authorize(
                 invocation,
                 %{"agent" => "Luna", "brief" => "task"},
                 projection,
                 %{max_children: 1, brief_max_bytes: 100}
               )
    end

    test "freezes structured output and isolation options in a delegation Plan" do
      {invocation, projection} = policy_fixture(:direct)

      schema = %{
        "type" => "object",
        "required" => ["summary"],
        "properties" => %{"summary" => %{"type" => "string"}}
      }

      assert {:ok,
              %Delegation.Plan{
                output_schema: ^schema,
                isolate?: true,
                brief: "task"
              }} =
               Delegation.authorize(
                 invocation,
                 %{
                   "agent" => "Luna",
                   "brief" => "task",
                   "output_schema" => schema,
                   "isolate" => true
                 },
                 projection,
                 %{max_children: 1, brief_max_bytes: 100}
               )

      assert {:ok, %{"summary" => "done"}} =
               Delegation.validate_output(~s({\"summary\":\"done\"}), schema)

      assert {:error, :delegation_output_missing_required} =
               Delegation.validate_output("{}", schema)
    end

    test "report truncation preserves UTF-8 and the byte cap" do
      report = Delegation.report(true, String.duplicate("é", 9_000), %{})

      assert report["truncated"]
      assert byte_size(report["output"]) <= 16_384
      assert String.valid?(report["output"])
    end
  end

  defp policy_fixture(mode, opts \\ []) do
    task = %Participant{
      id: "luna",
      name: "Luna",
      perspective: "task",
      kind: :task,
      provider: :simulator,
      model: nil
    }

    participants =
      if opts[:duplicate_name?],
        do: [task, %{task | id: "luna-2"}],
        else: [task]

    room = %Room{id: "room-policy", participants: participants}
    turn = %Turn{id: "turn-policy", room_id: room.id, mode: mode}

    invocation = %Invocation{
      id: "inv-policy",
      room_id: room.id,
      turn_id: turn.id,
      delegation_depth: 0,
      tool_runs: opts[:tool_runs] || %{},
      tool_run_order: opts[:tool_run_order] || []
    }

    projection = %Projection{
      rooms: %{room.id => room},
      turns: %{turn.id => turn}
    }

    {invocation, projection}
  end

  defp run_delegation_scenario(message) do
    stack = start_stack()
    room_id = new_room(stack)
    configure_room(room_id)

    {:ok, turn_id} = Engine.post_message(room_id, message, :direct, @engine)
    Wait.terminal_turn(@engine, turn_id)

    {turn_id}
  end

  defp suspended_parent(turn_id) do
    Wait.projection(@engine, fn projection ->
      projection.turns[turn_id]
      |> case do
        %{invocation_order: [parent_id | _]} -> suspended_invocation(projection, parent_id)
        _other -> false
      end
    end)
  end

  defp suspended_invocation(projection, parent_id) do
    case projection.invocations[parent_id] do
      %{status: :awaiting_delegation} -> parent_id
      _other -> false
    end
  end

  defp new_room(stack) do
    assert {:ok, room_id} = Engine.create_room("Delegation Room", stack.workspace, @engine)
    room_id
  end

  defp configure_room(room_id) do
    snapshot = Engine.snapshot(@engine)
    room = snapshot.rooms[room_id]
    primary = Enum.find(room.participants, &(&1.kind == :primary))

    assert {:ok, luna_id} =
             Engine.add_task_participant(room_id, @task_agent, "cheap test cycles", @engine)

    assert :ok = Engine.configure_participants(room_id, [primary.id], :simulator, nil, @engine)
    assert :ok = Engine.configure_participants(room_id, [luna_id], :simulator, nil, @engine)
  end

  defp start_stack(overrides \\ []) do
    workspace = Path.join(System.tmp_dir!(), "delegation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_delegation_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    catalog = start_supervised!({ScriptedCatalog, test_pid: self()})

    config =
      RuntimeConfig.fresh(
        [
          global_concurrency: 2,
          workspace_concurrency: 1,
          workspace_roots: [workspace],
          allow_simulator_provider: true
        ] ++
          overrides
      )

    start_engine(store, config, catalog)

    %{store: store, config: config, catalog: catalog, workspace: workspace}
  end

  defp start_engine(store, config, catalog) do
    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: catalog,
       agent_delay_ms: 0,
       config: config},
      restart: :temporary
    )
  end
end
