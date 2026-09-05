defmodule ReyCode.NativeProviderIntegrationTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{Engine, Projector}
  alias ReyCode.Provider.Catalog
  alias ReyCode.Test.Wait

  @agents __MODULE__.Agents
  @events __MODULE__.Events
  @workers __MODULE__.Workers
  @tasks __MODULE__.Tasks

  defmodule ModelWire do
    @moduledoc false
    @behaviour ReyCode.Provider.OpenAICompatible.HTTP

    @impl true
    def start(:get, _url, _headers, nil, _opts),
      do: {:ok, Jason.encode!(%{data: [%{id: "native-model"}]})}

    def start(:post, _url, _headers, body, _opts) do
      request = Jason.decode!(body)
      tool_result = Enum.find(request["messages"], &(&1["role"] == "tool"))
      {:ok, response(tool_result)}
    end

    @impl true
    def collect(body, on_event, acc) do
      case on_event.({:partial, body}, acc) do
        {:cont, next} -> {:ok, next, %{status: 200, headers: []}}
        {:halt, _next, error} -> {:error, error}
      end
    end

    defp response(nil) do
      call = %{
        index: 0,
        id: "native-write",
        type: "function",
        function: %{
          name: "write",
          arguments: Jason.encode!(%{path: "standalone.txt", content: "ReyCode owns execution"})
        }
      }

      sse(%{tool_calls: [call]}, "tool_calls")
    end

    defp response(%{"tool_call_id" => "native-write", "content" => content}) do
      %{"ok" => true, "output" => output} = Jason.decode!(content)
      true = String.contains?(output, "standalone.txt")
      sse(%{content: "ReyCode returned the approved tool result"}, "stop")
    end

    defp sse(delta, reason) do
      "data: " <>
        Jason.encode!(%{choices: [%{delta: delta, finish_reason: reason}]}) <>
        "\n\ndata: [DONE]\n\n"
    end
  end

  test "native discovery, model rounds, approval, execution, and replay share one lifecycle" do
    workspace =
      Path.join(System.tmp_dir!(), "reycode-native-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    config =
      RuntimeConfig.fresh(
        workspace_roots: [workspace],
        openai_compatible_transport: ModelWire
      )

    start_supervised!({Registry, keys: :unique, name: @agents})
    start_supervised!({Registry, keys: :duplicate, name: @events})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @workers})
    start_supervised!({Task.Supervisor, name: @tasks})

    store =
      start_supervised!({EventStore, name: nil, path: Path.join(workspace, "events.sqlite3")})

    catalog =
      start_supervised!(
        {Catalog, name: nil, registry: @events, task_supervisor: @tasks, config: config}
      )

    assert {:ok, _runtime} = Catalog.resolve_when_ready(:ollama, "native-model", catalog)

    opts = [
      name: __MODULE__.Engine,
      event_store: store,
      agent_registry: @agents,
      event_registry: @events,
      agent_supervisor: @workers,
      provider_catalog: catalog,
      config: config
    ]

    engine = start_supervised!({Engine, opts})
    assert {:ok, session_id} = Engine.create_blank_session("Native", workspace, engine)

    for provider <- [:opencode, :omp] do
      assert {:error, :unknown_provider} =
               Engine.configure_participants(
                 session_id,
                 ["assistant"],
                 provider,
                 "old/model",
                 engine
               )
    end

    assert :ok =
             Engine.configure_participants(
               session_id,
               ["assistant"],
               :ollama,
               "native-model",
               engine
             )

    assert {:ok, turn_id} =
             Engine.post_message(session_id, "Write standalone.txt", :direct, engine)

    invocation = Wait.invocation_status(engine, turn_id, :waiting_tool_approval)
    [run] = Map.values(invocation.tool_runs)
    assert run.authorization == :ask
    refute File.exists?(Path.join(workspace, "standalone.txt"))

    assert :ok = Engine.resolve_tool_run(invocation.id, run.id, :approve, engine)
    assert Wait.terminal_turn(engine, turn_id).outcome == :completed
    assert File.read!(Path.join(workspace, "standalone.txt")) == "ReyCode owns execution"

    projection = Engine.snapshot(engine)
    completed = projection.invocations[invocation.id]
    assert length(completed.rounds) == 2
    assert completed.tool_runs[run.id].status == :completed

    assert projection.messages[completed.message_id].body ==
             "ReyCode returned the approved tool result"

    assert Projector.replay(EventStore.load(store)) == projection

    stop_supervised!(Engine)
    restarted = start_supervised!({Engine, opts})
    assert Engine.snapshot(restarted) == projection
  end
end
