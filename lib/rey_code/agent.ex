defmodule ReyCode.Agent do
  @moduledoc "A supervised execution bridge for one provider invocation."

  use GenServer, restart: :temporary

  alias ReyCode.Orchestration.Engine.Client
  alias ReyCode.Provider.Catalog

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry = Keyword.fetch!(opts, :registry)
    invocation_id = Keyword.fetch!(opts, :invocation_id)
    name = {:via, Registry, {registry, invocation_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok, Map.new(opts), {:continue, :stream}}
  end

  @impl true
  def handle_continue(:stream, state) do
    case Client.invocation_request(state.engine, state.invocation_id) do
      {:terminal, _status} ->
        {:stop, :normal, state}

      {:ok, request} ->
        start_request(state, request)
    end
  end

  defp start_request(state, request) do
    case Catalog.resolve_when_ready(
           state.provider,
           request.participant.model,
           state.provider_catalog
         ) do
      {:ok, runtime} ->
        :ok = Client.invocation_started(state.engine, state.invocation_id)

        execute(state, request, runtime)

      {:error, reason} ->
        fail_unavailable_provider(state, reason)
    end
  end

  defp fail_unavailable_provider(state, reason) do
    error = %{
      "category" => "provider_unavailable",
      "message" => provider_error(reason),
      "retryable" => reason in [:provider_checking, :provider_check_timeout, :error]
    }

    :ok = Client.fail_invocation(state.engine, state.invocation_id, error)

    {:stop, :normal, state}
  end

  defp execute(state, request, runtime) do
    result =
      try do
        stream(runtime, request, fn frame ->
          Client.record_frame(state.engine, state.invocation_id, frame)
        end)
      rescue
        error ->
          {:error,
           %{
             "category" => "internal",
             "message" => Exception.message(error),
             "retryable" => false
           }}
      catch
        kind, reason ->
          {:error,
           %{
             "category" => "internal",
             "message" => Exception.format_banner(kind, reason),
             "retryable" => false
           }}
      end

    case result do
      {:ok, metadata} ->
        Client.complete_invocation(state.engine, state.invocation_id, metadata)

      {:error, error} ->
        Client.fail_invocation(state.engine, state.invocation_id, error)
    end

    {:stop, :normal, state}
  end

  defp stream(runtime, request, emit) do
    runtime.module.stream(runtime, request, emit)
  end

  @spec provider_error(atom()) :: String.t()
  defp provider_error(:missing), do: "Provider executable is not installed"
  defp provider_error(:available), do: "Provider needs credentials or an available model"
  defp provider_error(:unchecked), do: "Provider discovery is disabled"
  defp provider_error(:model_required), do: "Select a model before running this agent"
  defp provider_error(:model_unavailable), do: "The selected model is no longer available"
  defp provider_error(:unknown_provider), do: "Unknown provider runtime"
  defp provider_error(:provider_check_timeout), do: "Provider discovery timed out"
  defp provider_error(reason), do: "Provider is unavailable: #{reason}"
end
