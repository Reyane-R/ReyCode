defmodule ReyCode.AgentLoop do
  @moduledoc """
  The durable, provider-independent tool loop for one invocation.

  Each step first drains the latest round's pending tool runs (executing
  ready runs sequentially, pausing on the first awaiting approval), then —
  when every recorded call has a terminal run — streams exactly one provider
  round and records it. The loop completes only when a provider round returns
  no tool calls. All continuation state is durable, so any process can resume
  the loop after an approval decision or an engine restart.
  """

  alias ReyCode.{Agent, ArtifactStore, Failure}
  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Orchestration.Engine.SourceTask
  alias ReyCode.Orchestration.InvocationContextBoundary
  alias ReyCode.Provider
  alias ReyCode.Provider.{Catalog, ContextBudget, Response}
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  @max_tool_wait_ms 3_610_000

  @spec run(Agent.state()) :: Agent.step()
  def run(state) do
    case Client.invocation_request(state.engine, state.invocation_id) do
      {:terminal, _status} ->
        {:stop, state}

      {:waiting, _reason} ->
        {:stop, state}

      {:ok, request} ->
        drain_or_stream(state, request)
    end
  end

  defp drain_or_stream(state, request) do
    state.engine
    |> Client.take_tool_run(state.invocation_id)
    |> handle_tool_action(state, request)
  end

  defp handle_tool_action({:ok, :none}, state, request), do: stream_round(state, request)

  defp handle_tool_action({:ok, {:execute, run}}, state, request) do
    Agent.execute_tool_run(Map.put(state, :session_id, request.session_id), run)
    run(state)
  end

  defp handle_tool_action({:ok, {action, _run}}, state, _request)
       when action in [:continue, :denied],
       do: run(state)

  # Durable suspension: a child Invocation, owner decision, or existing worker
  # owns continuation until the Engine re-arms admission.
  defp handle_tool_action({:ok, {action, _run}}, state, _request)
       when action in [:delegate, :await, :busy, :question],
       do: {:stop, state}

  defp handle_tool_action({:waiting, _reason}, state, _request), do: {:stop, state}

  defp handle_tool_action({:error, reason}, state, _request) do
    Agent.fail(state, internal_error("tool run rejected: " <> inspect(reason)))
    {:stop, state}
  end

  defp stream_round(state, request) do
    case resolve_runtime(state, request) do
      {:ok, runtime} ->
        :ok = Client.invocation_started(state.engine, state.invocation_id)
        preflight_context(state, request, runtime)

      {:error, reason} ->
        Agent.fail(state, unavailable_provider_error(reason))
        {:stop, state}
    end
  end

  defp resolve_runtime(state, %{round_index: 0} = request) do
    Catalog.resolve_when_ready(
      state.provider,
      request.participant.model,
      state.provider_catalog
    )
  end

  defp resolve_runtime(state, _request),
    do: Catalog.resolve_continuation(state.provider, state.provider_catalog)

  defp preflight_context(state, request, runtime) do
    case Provider.context_budget(runtime, request) do
      {:ok, %ContextBudget{status: :ready}} -> stream_provider(state, request, runtime)
      {:ok, %ContextBudget{} = budget} -> maintain_context(state, request, runtime, budget)
      :unassessed -> stream_provider(state, request, runtime)
      {:error, reason} -> fail_context_maintenance(state, reason)
    end
  end

  defp maintain_context(state, request, runtime, budget) do
    max_summary_bytes =
      min(
        InvocationContextBoundary.maximum_summary_bytes(),
        min(budget.target_prompt_bytes, budget.target_input_tokens * 4)
      )

    case Client.prepare_context_boundary(state.engine, state.invocation_id, max_summary_bytes) do
      {:ok, boundary} -> record_context_boundary(state, runtime, boundary)
      :unchanged -> stream_provider(state, request, runtime)
      {:error, :context_summary_budget_too_small} -> stream_provider(state, request, runtime)
      {:error, reason} -> fail_context_maintenance(state, reason)
    end
  end

  defp record_context_boundary(state, runtime, boundary) do
    case Client.record_context_boundary(state.engine, state.invocation_id, boundary) do
      :ok ->
        rebuild_after_context_boundary(state, runtime)

      {:error, reason}
      when reason in [
             :stale_invocation_context_boundary,
             :conflicting_invocation_context_boundary
           ] ->
        rebuild_after_context_boundary(state, runtime)

      {:error, :invocation_terminal} ->
        {:stop, state}

      {:error, reason} ->
        fail_context_maintenance(state, reason)
    end
  end

  defp rebuild_after_context_boundary(state, runtime) do
    case Client.invocation_request(state.engine, state.invocation_id) do
      {:ok, request} -> reassess_context_target(state, request, runtime)
      {:terminal, _status} -> {:stop, state}
      {:waiting, _reason} -> {:stop, state}
    end
  end

  defp reassess_context_target(state, request, runtime) do
    case Provider.context_budget(runtime, request) do
      {:ok, %ContextBudget{} = budget} ->
        if context_target_reached?(budget),
          do: stream_provider(state, request, runtime),
          else: maintain_context(state, request, runtime, budget)

      :unassessed ->
        stream_provider(state, request, runtime)

      {:error, reason} ->
        fail_context_maintenance(state, reason)
    end
  end

  defp context_target_reached?(budget) do
    budget.prompt_bytes <= budget.target_prompt_bytes and
      budget.estimated_prompt_tokens <= budget.target_input_tokens
  end

  defp stream_provider(state, request, runtime) do
    case Agent.stream(state, request, runtime) do
      {:ok, %Response{} = response} ->
        record_round(state, request, response)

      {:error, error} ->
        Agent.fail(state, error)
        {:stop, state}
    end
  end

  defp fail_context_maintenance(state, reason) do
    Agent.fail(state, internal_error("provider context maintenance failed: " <> inspect(reason)))
    {:stop, state}
  end

  defp record_round(state, request, response) do
    case Client.record_round(
           state.engine,
           state.invocation_id,
           request.round_index,
           response |> Response.to_wire() |> Map.put("steering", request.steering)
         ) do
      {:ok, :final} ->
        :ok =
          Client.complete_invocation(state.engine, state.invocation_id, %{
            "usage" => response.usage
          })

        {:stop, state}

      {:ok, :continue} ->
        run(state)

      {:error, reason} ->
        Agent.fail(state, internal_error("provider round rejected: " <> inspect(reason)))
        {:stop, state}
    end
  end

  @doc "Executes one ready tool run and records its terminal outcome."
  @spec execute_tool_run(Agent.state(), map()) :: :ok
  def execute_tool_run(state, run) do
    case Client.tool_run_started(state.engine, state.invocation_id, run.id) do
      :ok -> execute_started_tool_run(state, run, ordinary_tool_request(run))
      {:ok, %Request{} = request} -> execute_started_tool_run(state, run, request)
      {:error, {:verified_change_denied, _reason}} -> :ok
      {:error, :strategy_review_tools_forbidden} -> :ok
      rejected -> raise MatchError, term: rejected
    end
  end

  defp ordinary_tool_request(run) do
    Request.new(
      tool: run.tool,
      arguments: run.arguments,
      workspace: run.workspace,
      roots: run.workspace_roots,
      request_id: run.id
    )
  end

  defp execute_started_tool_run(state, run, tool_request) do
    tool_request = %{tool_request | session_id: Map.get(state, :session_id)}
    config = state.config
    # Adapters retain their own (usually much shorter) deadlines. The caller's
    # one-hour envelope never kills a lease while subprocess cleanup is running.
    result =
      case SourceTask.run(
             state.engine,
             {:invocation, state.invocation_id},
             fn -> ToolRegistry.execute(tool_request, config) end,
             @max_tool_wait_ms
           ) do
        {:ok, result} -> result
        {:error, reason} -> Result.error(reason)
      end

    result = ArtifactStore.spool(result, state.config.artifacts, state.invocation_id, run.id)
    record_tool_result(state, run, Result.to_wire(result))
  end

  defp record_tool_result(state, run, %{"ok" => true} = result) do
    :ok =
      Client.tool_run_completed(
        state.engine,
        state.invocation_id,
        run.id,
        result
      )
  end

  defp record_tool_result(state, run, result) do
    :ok =
      Client.tool_run_failed(
        state.engine,
        state.invocation_id,
        run.id,
        result
      )
  end

  defp internal_error(message), do: Failure.new(:internal, message)

  defp unavailable_provider_error(reason) do
    Failure.new(
      :provider_unavailable,
      Agent.provider_error(reason),
      reason in [:provider_checking, :provider_check_timeout, :error]
    )
  end
end
