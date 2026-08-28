defmodule ReyCode.Orchestration.TierOneDelegationTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.{Response, Runtime, ToolCall}
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.MergeReview

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  defmodule Catalog do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    alias ReyCode.Provider.Runtime

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({action, _provider, _model}, _from, test_pid)
        when action in [:resolve, :resolve_when_ready] do
      runtime = %Runtime{
        module: ReyCode.Orchestration.TierOneDelegationTest.Provider,
        status: :available,
        executable: test_pid
      }

      {:reply, {:ok, runtime}, test_pid}
    end
  end

  defmodule Provider do
    @behaviour ReyCode.Provider
    alias ReyCode.Provider.{Frame, Response, Runtime, ToolCall}

    @schema %{
      "type" => "object",
      "required" => ["result"],
      "properties" => %{"result" => %{"type" => "string"}}
    }

    @impl true
    def stream(%Runtime{executable: test_pid}, request, emit) do
      case {request.label, request.round_index} do
        {"assistant response", 0} ->
          parent_start(request)

        {"assistant response", 1} ->
          parent_finish(test_pid, request, emit)

        {"delegated task", 0} ->
          if String.contains?(request.system_prompt, "isolated patch"),
            do: isolated_patch(request, emit),
            else: worker_peer(request)

        {"delegated task", round} when round in [1, 2] ->
          worker_continue_or_finish(test_pid, request, emit, round)

        {"integration task", 0} ->
          integrator_finish(test_pid, request, emit)

        {"detached task", 0} ->
          detached_finish(test_pid, request, emit)

        other ->
          {:error, ReyCode.Failure.new(:internal, "unexpected scripted round #{inspect(other)}")}
      end
    end

    defp parent_start(request) do
      case directive(request) do
        "wave" ->
          {:ok,
           Response.new(
             tool_calls: [
               ToolCall.new("wave-call", "spawn_tasks", %{
                 "shared_context" => "Use the public interface and coordinate exact ownership.",
                 "tasks" => [
                   %{"agent" => "Luna", "brief" => "worker Luna", "output_schema" => @schema},
                   %{"agent" => "Nova", "brief" => "worker Nova", "output_schema" => @schema}
                 ],
                 "integrator" => %{
                   "agent" => "Release",
                   "brief" => "integrate worker reports",
                   "output_schema" => @schema
                 }
               })
             ]
           )}

        "detach" ->
          {:ok,
           Response.new(
             tool_calls: [
               ToolCall.new("detach-call", "spawn_task", %{
                 "agent" => "Luna",
                 "brief" => "detached work",
                 "output_schema" => @schema,
                 "detach" => true
               })
             ]
           )}

        decision when decision in ["merge", "discard"] ->
          {:ok,
           Response.new(
             tool_calls: [
               ToolCall.new("merge-call", "spawn_task", %{
                 "agent" => "Luna",
                 "brief" => "isolated patch #{decision}",
                 "output_schema" => @schema,
                 "isolate" => true
               })
             ]
           )}
      end
    end

    defp parent_finish(test_pid, request, emit) do
      send(test_pid, {:parent_tool_result, latest_tool_content(request)})
      response_with_text(emit, request, "parent done")
    end

    defp worker_peer(request) do
      {sender, target} = worker_names(request)

      {:ok,
       Response.new(
         tool_calls: [
           ToolCall.new("peer-#{sender}", "send_peer", %{
             "target" => target,
             "body" => "#{sender} owns its assigned worker result"
           })
         ]
       )}
    end

    defp isolated_patch(request, emit) do
      value =
        if String.contains?(request.system_prompt, "discard"), do: "discarded\n", else: "after\n"

      File.write!(Path.join(request.workspace, "sample.txt"), value)
      response_with_text(emit, request, Jason.encode!(%{"result" => String.trim(value)}))
    end

    defp worker_continue_or_finish(test_pid, request, emit, round) do
      {agent, target} = worker_names(request)
      contents = user_contents(request)

      if Enum.any?(contents, &String.contains?(&1, "Peer message from")) or round == 2 do
        send(test_pid, {:worker_context, agent, contents})
        response_with_text(emit, request, Jason.encode!(%{"result" => "#{agent} done"}))
      else
        {:ok,
         Response.new(
           tool_calls: [
             ToolCall.new("peer-wait-#{agent}", "send_peer", %{
               "target" => target,
               "body" => "#{agent} is waiting for peer coordination"
             })
           ]
         )}
      end
    end

    defp worker_names(request) do
      if String.contains?(request.system_prompt, "Luna task agent"),
        do: {"Luna", "Nova"},
        else: {"Nova", "Luna"}
    end

    defp integrator_finish(test_pid, request, emit) do
      send(test_pid, {:integrator_context, message_contents(request)})
      response_with_text(emit, request, Jason.encode!(%{"result" => "integrated"}))
    end

    defp detached_finish(test_pid, request, emit) do
      send(test_pid, {:detached_waiting, request.invocation_id, self()})

      receive do
        :finish ->
          response_with_text(emit, request, Jason.encode!(%{"result" => "detached done"}))
      after
        5_000 -> {:error, ReyCode.Failure.new(:timeout, "detached fixture timed out")}
      end
    end

    defp response_with_text(emit, request, text) do
      :ok = emit.(Frame.text_delta(request.resume_from + 1, text))
      {:ok, Response.new(text: text)}
    end

    defp directive(request) do
      Enum.find_value(request.messages, fn
        %{role: :user, content: content}
        when content in ["wave", "detach", "merge", "discard"] ->
          content

        _other ->
          nil
      end)
    end

    defp latest_tool_content(request) do
      request.messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{role: :tool, content: content} -> content
        _other -> nil
      end)
    end

    defp user_contents(request) do
      Enum.flat_map(request.messages, fn
        %{role: :user, content: content} -> [content]
        _other -> []
      end)
    end

    defp message_contents(request) do
      Enum.flat_map(request.messages, fn
        %{content: content} when is_binary(content) -> [content]
        _other -> []
      end)
    end
  end

  setup do
    workspace = Path.join(System.tmp_dir!(), "tier_one_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    git = System.find_executable("git")
    File.write!(Path.join(workspace, "sample.txt"), "before\n")
    {_output, 0} = System.cmd(git, ["init"], cd: workspace, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd(git, ["config", "user.email", "reycode@example.invalid"], cd: workspace)

    {_output, 0} = System.cmd(git, ["config", "user.name", "ReyCode Test"], cd: workspace)
    {_output, 0} = System.cmd(git, ["add", "sample.txt"], cd: workspace)
    {_output, 0} = System.cmd(git, ["commit", "-m", "initial"], cd: workspace)

    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_tier_one_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})
    catalog = start_supervised!({Catalog, self()})

    config =
      RuntimeConfig.fresh(
        global_concurrency: 4,
        workspace_concurrency: 4,
        workspace_roots: [workspace],
        allow_simulator_provider: true
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
       config: config},
      restart: :temporary
    )

    {:ok, session_id} = Engine.create_blank_session("Tier One", workspace, @engine)
    configure_participants(session_id)
    %{session_id: session_id}
  end

  test "wave runs workers, exchanges peer messages, validates reports, then starts integrator", %{
    session_id: session_id
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "wave", :direct, @engine)
    Wait.terminal_turn(@engine, turn_id)
    projection = Engine.snapshot(@engine)

    assert_receive {:worker_context, "Luna", luna_context}, 5_000
    assert_receive {:worker_context, "Nova", nova_context}, 5_000
    assert Enum.any?(luna_context, &String.contains?(&1, "Peer message from Nova"))
    assert Enum.any?(nova_context, &String.contains?(&1, "Peer message from Luna"))

    assert_receive {:integrator_context, integrator_context}, 5_000
    assert Enum.any?(integrator_context, &String.contains?(&1, ~s({"result":"Luna done"})))
    assert Enum.any?(integrator_context, &String.contains?(&1, ~s({"result":"Nova done"})))

    assert_receive {:parent_tool_result, parent_result}, 5_000
    assert parent_result =~ "integrated"

    [parent_id | child_ids] = projection.turns[turn_id].invocation_order
    assert length(child_ids) == 3
    parent = projection.invocations[parent_id]
    [run_id] = parent.tool_run_order
    run = parent.tool_runs[run_id]
    assert run.tool == "spawn_tasks"
    assert run.status == :completed
    assert run.child_invocation_ids == child_ids
    assert Enum.all?(child_ids, &(projection.invocations[&1].status == :completed))

    assert Enum.all?(
             child_ids,
             &(projection.invocations[&1].execution_context.output_schema != nil)
           )
  end

  test "detached delegation lets the source Turn finish and auto-delivers later", %{
    session_id: session_id
  } do
    {:ok, source_turn_id} = Engine.post_message(session_id, "detach", :direct, @engine)

    assert_receive {:detached_waiting, child_id, child_pid}, 5_000
    Wait.terminal_turn(@engine, source_turn_id)
    source_projection = Engine.snapshot(@engine)
    assert source_projection.turns[source_turn_id].outcome == :completed

    detached_turn =
      source_projection.turns
      |> Map.values()
      |> Enum.find(&(&1.source_invocation_id != nil and &1.detached?))

    assert detached_turn.status == :running
    assert source_projection.sessions[session_id].active_turn_id == nil

    send(child_pid, :finish)
    Wait.terminal_turn(@engine, detached_turn.id)
    final_projection = Engine.snapshot(@engine)
    assert final_projection.turns[detached_turn.id].outcome == :completed
    assert final_projection.invocations[child_id].status == :completed

    message = final_projection.messages[final_projection.invocations[child_id].message_id]
    assert message.body == ~s({"result":"detached done"})
    assert message.status == :completed
  end

  test "isolated child pauses for owner Apply before touching the source", %{
    session_id: session_id
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "merge", :direct, @engine)

    child =
      Wait.projection(@engine, fn projection ->
        projection.turns[turn_id].invocation_order
        |> Enum.map(&projection.invocations[&1])
        |> Enum.find(
          &match?(%{pending_tool_review: %{tool: "merge"}, status: :waiting_tool_approval}, &1)
        )
      end)

    assert File.read!(
             Path.join(Engine.snapshot(@engine).sessions[session_id].workspace, "sample.txt")
           ) ==
             "before\n"

    assert child.pending_tool_review.arguments["diff"] =~ "+after"
    assert {:noreply, resolved} = MergeReview.submit(merge_term(child))
    assert resolved.assigns.notice == "Patch applied"
    Wait.terminal_turn(@engine, turn_id)

    assert File.read!(
             Path.join(Engine.snapshot(@engine).sessions[session_id].workspace, "sample.txt")
           ) ==
             "after\n"
  end

  test "isolated child Discard removes the worktree and preserves the source", %{
    session_id: session_id
  } do
    {:ok, turn_id} = Engine.post_message(session_id, "discard", :direct, @engine)

    child =
      Wait.projection(@engine, fn projection ->
        projection.turns[turn_id].invocation_order
        |> Enum.map(&projection.invocations[&1])
        |> Enum.find(&match?(%{pending_tool_review: %{tool: "merge"}}, &1))
      end)

    assert {:noreply, resolved} = MergeReview.handle_input("D", merge_term(child))
    assert resolved.assigns.notice == "Patch discarded"
    Wait.terminal_turn(@engine, turn_id)
    workspace = Engine.snapshot(@engine).sessions[session_id].workspace
    assert File.read!(Path.join(workspace, "sample.txt")) == "before\n"
    refute File.exists?(child.execution_context.isolation["workspace"])
  end

  defp merge_term(child) do
    %Breeze.Term{
      assigns: %{
        engine: @engine,
        merge_review: %{child_invocation_id: child.id, offset: 0},
        modal: :merge_review,
        notice: nil,
        projection: Engine.snapshot(@engine)
      }
    }
  end

  defp configure_participants(session_id) do
    session = Engine.snapshot(@engine).sessions[session_id]
    primary = Enum.find(session.participants, &(&1.kind == :primary))
    :ok = Engine.configure_participants(session_id, [primary.id], :simulator, nil, @engine)

    Enum.each(
      [
        {"Luna", "worker one"},
        {"Nova", "worker two"},
        {"Release", "integration owner"}
      ],
      fn {name, responsibility} ->
        {:ok, participant_id} =
          Engine.add_task_participant(session_id, name, responsibility, @engine)

        :ok =
          Engine.configure_participants(session_id, [participant_id], :simulator, nil, @engine)
      end
    )
  end
end
