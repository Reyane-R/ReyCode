defmodule ReyCode.Provider do
  @moduledoc """
  Logical interface implemented by streaming provider adapters.

  One `stream/3` call performs exactly one bounded ProviderRound. It may emit
  ordered display Frames and returns either a normalized Response or a typed
  Failure. Providers never execute tools, mutate orchestration state, retry,
  or schedule follow-up rounds. The caller owns the total deadline,
  cancellation, retry policy, frame durability, and Invocation recovery.
  Adapter implementations translate foreign faults at this seam.
  Adapters may also expose exact request-budget preflight; unsupported adapters
  stream unchanged.
  """

  alias ReyCode.Failure
  alias ReyCode.Provider.{ContextBudget, Frame, Request, Response, Runtime}

  @type emit :: (Frame.t() -> :ok)
  @type result :: {:ok, Response.t()} | {:error, Failure.t()}
  @type context_budget_result :: {:ok, ContextBudget.t()} | :unassessed | {:error, term()}

  @callback stream(Runtime.t(), Request.t(), emit()) :: result()
  @callback context_budget(Runtime.t(), Request.t()) :: context_budget_result()

  @optional_callbacks context_budget: 2

  @doc "Assesses an exact provider request when the adapter supports preflight."
  @spec context_budget(Runtime.t(), Request.t()) :: context_budget_result()
  def context_budget(%Runtime{module: module} = runtime, %Request{} = request) do
    if Code.ensure_loaded?(module) and function_exported?(module, :context_budget, 2) do
      invoke_context_budget(module, runtime, request)
    else
      :unassessed
    end
  end

  defp invoke_context_budget(module, runtime, request) do
    case module.context_budget(runtime, request) do
      {:ok, %ContextBudget{}} = assessed -> assessed
      :unassessed -> :unassessed
      {:error, _reason} = error -> error
      _invalid -> {:error, Failure.new(:invalid_output, "Provider returned invalid preflight")}
    end
  rescue
    error -> {:error, Failure.new(:internal, Exception.message(error))}
  catch
    kind, reason -> {:error, Failure.new(:internal, Exception.format_banner(kind, reason))}
  end
end
