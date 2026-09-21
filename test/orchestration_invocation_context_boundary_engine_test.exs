defmodule ReyCode.Orchestration.InvocationContextBoundaryEngineTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, Projector}
  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Provider.{Response, Runtime, ToolCall}
  alias ReyCode.Test.Wait

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule Catalog do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid))
    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready, :resolve_continuation] do
      runtime = %Runtime{
        module: ReyCode.Orchestration.InvocationContextBoundaryEngineTest.Provider,
        status: :available,
        config: %{test_pid: test_pid}
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule Provider do
    @behaviour ReyCode.Provider

    @impl true
    def stream(%Runtime{config: %{test_pid: test_pid}}, request, _emit) do
      case request.round_index do
        0 ->
          {:ok, Response.new(tool_calls: [ToolCall.new("call-0", "read", %{"path" => "a.txt"})])}

        1 ->
          {:ok, Response.new(tool_calls: [ToolCall.new("call-1", "read", %{"path" => "b.txt"})])}

        2 ->
          send(test_pid, {:boundary_request, request})

          receive do
            :finish_boundary_invocation -> {:ok, Response.new(text: "done")}
          end
      end
    end
  end

  @tag :tmp_dir
  test "records a current boundary idempotently and rejects conflicting or stale content", %{
    tmp_dir: workspace
  } do
    File.write!(Path.join(workspace, "a.txt"), "alpha\n")
    File.write!(Path.join(workspace, "b.txt"), "beta\n")
    database = Path.join(workspace, "events.sqlite3")

    store = start_supervised!({EventStore, name: nil, path: database})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({Catalog, test_pid: self()})

    config = RuntimeConfig.fresh(workspace_roots: [workspace])

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

    assert {:ok, session_id} = Engine.create_blank_session("Boundary", workspace, @engine)
    assert {:ok, turn_id} = Engine.post_message(session_id, "Read both files", :direct, @engine)
    assert_receive {:boundary_request, request}, 2_000

    invocation = Engine.snapshot(@engine).invocations[request.invocation_id]

    assert {:ok, boundary} =
             Client.prepare_context_boundary(@engine, invocation.id, 32_768)

    assert :ok = Client.record_context_boundary(@engine, invocation.id, boundary)
    assert :ok = Client.record_context_boundary(@engine, invocation.id, boundary)

    projected =
      Engine.snapshot(@engine).invocations[invocation.id].execution_context.context_boundary

    assert projected.through_round_index == 0
    assert projected.source_digest == boundary.source_digest

    conflict = %{
      boundary
      | summary: boundary.summary <> "x",
        summary_bytes: boundary.summary_bytes + 1
    }

    assert {:error, :conflicting_invocation_context_boundary} =
             Client.record_context_boundary(@engine, invocation.id, conflict)

    stale = %{boundary | source_digest: String.duplicate("0", 64)}

    assert {:error, :conflicting_invocation_context_boundary} =
             Client.record_context_boundary(@engine, invocation.id, stale)

    boundary_events =
      store
      |> EventStore.load()
      |> Enum.count(&(&1.type == :invocation_context_compacted))

    assert boundary_events == 1
    send(GenServer.whereis(via_agent(invocation.id)), :finish_boundary_invocation)
    assert Wait.terminal_turn(@engine, turn_id).outcome == :completed
    assert Projector.replay(EventStore.load(store)) == Engine.snapshot(@engine)
  end

  defp via_agent(invocation_id) do
    {:via, Registry, {@agent_registry, invocation_id}}
  end
end
