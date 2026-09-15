defmodule ReyCode.Agent do
  @moduledoc """
  A supervised execution bridge for one provider invocation.

  The process owns durable frame delivery, lifecycle, and error containment around
  `ReyCode.AgentLoop`, which performs the durable round/tool-run steps.
  """

  use GenServer, restart: :temporary

  alias ReyCode.{AgentLoop, Failure}
  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Provider.{Response, Runtime}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry = Keyword.fetch!(opts, :registry)
    invocation_id = Keyword.fetch!(opts, :invocation_id)
    name = {:via, Registry, {registry, invocation_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @type state :: %{
          required(:engine) => term(),
          required(:invocation_id) => String.t(),
          required(:provider) => atom() | String.t(),
          required(:provider_catalog) => term(),
          optional(atom()) => term()
        }

  @type step :: {:stop, state()}

  @impl true
  def init(opts) do
    {:ok, Map.new(opts), {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    case AgentLoop.run(state) do
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  @doc "Streams one provider round, persisting each already-batched frame before acknowledging it."
  @spec stream(state(), map(), Runtime.t()) :: {:ok, Response.t()} | {:error, Failure.t()}
  def stream(state, request, runtime) do
    # Native providers already enforce byte/latency batching. A second
    # count-only buffer here hid short responses until stream completion.
    emit = fn frame -> record_frame!(state.engine, state.invocation_id, frame) end

    try do
      runtime.module.stream(runtime, request, emit)
    rescue
      error -> {:error, internal_error(Exception.message(error))}
    catch
      kind, reason -> {:error, internal_error(Exception.format_banner(kind, reason))}
    end
  end

  @doc "Executes one ready tool run through the registry and records its outcome."
  @spec execute_tool_run(state(), map()) :: :ok
  def execute_tool_run(state, run), do: AgentLoop.execute_tool_run(state, run)

  @doc "Fails the invocation with a typed internal Failure."
  @spec fail(state(), Failure.t()) :: :ok
  def fail(state, error) do
    :ok = Client.fail_invocation(state.engine, state.invocation_id, error)
  end

  @spec provider_error(atom()) :: String.t()
  def provider_error(:missing), do: "Model API is unavailable"
  def provider_error(:available), do: "Provider needs credentials or an available model"
  def provider_error(:unchecked), do: "Provider discovery is disabled"
  def provider_error(:model_required), do: "Select a model before running this agent"
  def provider_error(:model_unavailable), do: "The selected model is no longer available"
  def provider_error(:unknown_provider), do: "Select a supported model API in /connect"
  def provider_error(:provider_check_timeout), do: "Provider discovery timed out"
  def provider_error(reason), do: "Provider is unavailable: #{inspect(reason)}"

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp record_frame!(engine, invocation_id, frame) do
    case Client.record_frames(engine, invocation_id, [frame]) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "frame rejected: " <> inspect(reason)
    end
  end

  defp internal_error(message), do: Failure.new(:internal, message)
end
