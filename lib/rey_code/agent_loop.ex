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

  alias ReyCode.{Agent, Failure}
  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Provider.Catalog
  alias ReyCode.Provider.Response
  alias ReyCode.Tool.{Request, Result}
  alias ReyCode.ToolRegistry

  @max_rounds 16

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
    case Client.take_tool_run(state.engine, state.invocation_id) do
      {:ok, :none} ->
        provider_round(state, request)

      {:ok, {:execute, run}} ->
        Agent.execute_tool_run(state, run)
        run(state)

      {:ok, {:await, _run}} ->
        {:stop, state}

      {:ok, {:busy, _run}} ->
        {:stop, state}

      {:ok, {:denied, _run}} ->
        run(state)

      {:error, reason} ->
        Agent.fail(state, internal_error("tool run rejected: " <> inspect(reason)))
        {:stop, state}
    end
  end

  defp provider_round(state, request) do
    if request.round_index >= @max_rounds do
      Agent.fail(state, internal_error("tool loop exceeded #{@max_rounds} provider rounds"))
      {:stop, state}
    else
      stream_round(state, request)
    end
  end

  defp stream_round(state, request) do
    case Catalog.resolve_when_ready(
           state.provider,
           request.participant.model,
           state.provider_catalog
         ) do
      {:ok, runtime} ->
        :ok = Client.invocation_started(state.engine, state.invocation_id)

        case Agent.stream(state, request, runtime) do
          {:ok, %Response{} = response} ->
            record_round(state, request, response)

          {:error, error} ->
            Agent.fail(state, error)
            {:stop, state}
        end

      {:error, reason} ->
        Agent.fail(state, unavailable_provider_error(reason))
        {:stop, state}
    end
  end

  defp record_round(state, request, response) do
    case Client.record_round(
           state.engine,
           state.invocation_id,
           request.round_index,
           Response.to_wire(response)
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
    :ok = Client.tool_run_started(state.engine, state.invocation_id, run.id)

    tool_request =
      Request.new(
        tool: run.tool,
        arguments: run.arguments,
        workspace: run.workspace,
        request_id: run.id
      )

    result = ToolRegistry.execute(tool_request, state.config)
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
