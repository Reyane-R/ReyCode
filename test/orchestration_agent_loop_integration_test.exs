defmodule ReyCode.Orchestration.AgentLoopIntegrationTest do
  @moduledoc """
  Engine-level integration for the native agent loop.

  A scripted catalog resolves every provider request to a scripted provider;
  round zero requests a real workspace tool, the durable loop executes it
  through the trusted registry, and round one observes the recorded tool
  result inside the rebuilt conversation before finishing the invocation.
  """

  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}

  alias ReyCode.Orchestration.Engine

  alias ReyCode.Provider.{Frame, Response, Runtime, ToolCall}

  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule ScriptedCatalog do
    use GenServer

    alias ReyCode.Orchestration.AgentLoopIntegrationTest.ScriptedProvider
    alias ReyCode.Provider.Runtime

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid))

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready, :resolve_continuation] do
      runtime = %Runtime{
        module: ScriptedProvider,
        status: :available,
        config: %{test_pid: test_pid}
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule ScriptedProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.{Frame, Response, ToolCall}

    @impl true
    def stream(%Runtime{config: %{test_pid: test_pid}}, request, emit) do
      send(test_pid, {:provider_round, request.round_index})

      case request.round_index do
        0 ->
          :ok = emit.(Frame.agent_note(request.resume_from + 1, "checking the workspace"))

          {:ok,
           Response.new(
             tool_calls: [
               ToolCall.new("call-1", "read", %{"path" => "hello.txt"})
             ]
           )}

        1 ->
          tool_result =
            Enum.find_value(request.messages, fn
              %{role: :tool, content: content} -> content
              _other -> nil
            end)

          send(test_pid, {:tool_result_in_conversation, tool_result})

          {:ok,
           Response.new(
             text: "done",
             usage: %{"prompt_tokens" => 3, "completion_tokens" => 2}
           )}

        other ->
          send(test_pid, {:unexpected_round, other})
          {:error, %{category: "internal", message: "scripted loop overrun", retryable: false}}
      end
    end
  end

  defmodule ContextCatalog do
    use GenServer

    alias ReyCode.Orchestration.AgentLoopIntegrationTest.ContextProvider
    alias ReyCode.Provider.Runtime

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid))

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready, :resolve_continuation] do
      runtime = %Runtime{
        module: ContextProvider,
        status: :available,
        config: %{test_pid: test_pid}
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule ContextProvider do
    @behaviour ReyCode.Provider

    alias ReyCode.Provider.{ContextBudget, Response, Runtime, ToolCall}

    @impl true
    def context_budget(%Runtime{config: %{test_pid: test_pid}}, request) do
      summary? = has_invocation_summary?(request.messages)
      assistant_count = Enum.count(request.messages, &(&1.role == :assistant))

      prompt_bytes =
        case {request.round_index, summary?, assistant_count} do
          {0, _summary?, _count} -> 100
          {1, _summary?, _count} -> 800
          {2, false, _count} -> 800
          {2, true, 1} -> 500
          {3, true, 2} -> 1_001
          {3, true, 1} -> 500
        end

      budget = ContextBudget.assess(prompt_bytes, 1_000, 10_000, nil, 1_000)

      send(
        test_pid,
        {:context_preflight, request.round_index, summary?, assistant_count, budget.status}
      )

      {:ok, budget}
    end

    @impl true
    def stream(%Runtime{config: %{test_pid: test_pid}}, request, _emit) do
      summary? = has_invocation_summary?(request.messages)
      send(test_pid, {:context_stream, request.round_index, summary?, request.messages})

      case request.round_index do
        0 ->
          {:ok,
           Response.new(
             text: "first read",
             tool_calls: [ToolCall.new("context-call-0", "read", %{"path" => "a.txt"})]
           )}

        1 ->
          {:ok,
           Response.new(
             text: "second read",
             tool_calls: [ToolCall.new("context-call-1", "read", %{"path" => "b.txt"})]
           )}

        2 ->
          {:ok,
           Response.new(
             text: "third read",
             tool_calls: [ToolCall.new("context-call-2", "read", %{"path" => "a.txt"})]
           )}

        3 ->
          {:ok, Response.new(text: "context maintained")}
      end
    end

    defp has_invocation_summary?(messages) do
      Enum.any?(messages, fn message ->
        message.role == :user and is_binary(message.content) and
          String.contains?(message.content, "durable summary of earlier rounds")
      end)
    end
  end

  test "executes a scripted tool round durably and completes on the next provider round" do
    workspace = Path.join(System.tmp_dir!(), "agent_loop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    File.write!(Path.join(workspace, "hello.txt"), "hello from workspace\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_agent_loop_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({ScriptedCatalog, test_pid: self()})

    config =
      RuntimeConfig.fresh(
        global_concurrency: 2,
        workspace_concurrency: 1,
        workspace_roots: [workspace]
      )

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

    assert {:ok, session_id} = Engine.create_blank_session("Loop Room", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(session_id, "Read hello.txt", :direct, @engine)

    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

    refute_received {:unexpected_round, _round}

    assert_received {:provider_round, 0}
    assert_receive {:tool_result_in_conversation, tool_result_json}
    assert tool_result_json =~ "hello from workspace"
    assert_received {:provider_round, 1}

    snapshot = Engine.snapshot(@engine)
    [invocation_id] = snapshot.turns[turn_id].invocation_order
    invocation = snapshot.invocations[invocation_id]

    assert [%{status: :completed, result: %{"ok" => true, "output" => output}}] =
             Map.values(invocation.tool_runs)

    assert output =~ "hello from workspace"

    assert [%{}, %{text: "done"}] = invocation.rounds
    assert invocation.notes == ["checking the workspace"]
    assert is_map(invocation.usage) and map_size(invocation.usage) > 0
  end

  test "automatically persists and rebuilds context before budgeted continuations" do
    workspace =
      Path.join(System.tmp_dir!(), "agent_loop_context_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "a.txt"), String.duplicate("a", 4_000))
    File.write!(Path.join(workspace, "b.txt"), String.duplicate("b", 4_000))
    on_exit(fn -> File.rm_rf!(workspace) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_agent_loop_context_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({ContextCatalog, test_pid: self()})

    config =
      RuntimeConfig.fresh(
        global_concurrency: 2,
        workspace_concurrency: 1,
        workspace_roots: [workspace]
      )

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

    assert {:ok, session_id} = Engine.create_blank_session("Context Room", workspace, @engine)

    assert {:ok, turn_id} =
             Engine.post_message(session_id, "Read both context files", :direct, @engine)

    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed

    assert_received {:context_preflight, 1, false, 1, :maintenance_required}
    assert_received {:context_stream, 1, false, _messages}
    assert_received {:context_preflight, 2, false, 2, :maintenance_required}
    assert_received {:context_preflight, 2, true, 1, :ready}
    assert_received {:context_stream, 2, true, _messages}
    refute_received {:context_stream, 2, false, _messages}
    assert_received {:context_preflight, 3, true, 2, :too_large}
    assert_received {:context_preflight, 3, true, 1, :ready}
    assert_received {:context_stream, 3, true, messages}

    assistant_messages = Enum.filter(messages, &(&1.role == :assistant))
    assert [%{tool_calls: [%ToolCall{id: "context-call-2"}]}] = assistant_messages

    snapshot = Engine.snapshot(@engine)
    [invocation_id] = snapshot.turns[turn_id].invocation_order
    boundary = snapshot.invocations[invocation_id].execution_context.context_boundary
    assert boundary.through_round_index == 1

    events = EventStore.load(store)
    boundary_events = Enum.filter(events, &(&1.type == :invocation_context_compacted))
    assert length(boundary_events) == 2
    boundary_event = List.last(boundary_events)

    final_round_event =
      Enum.find(events, fn event ->
        event.type == :provider_round_recorded and event.data["round_index"] == 3
      end)

    assert boundary_event.sequence < final_round_event.sequence
  end
end
