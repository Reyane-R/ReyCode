defmodule ReyCode.LocalEngine.Proxy do
  @moduledoc "Preserves existing client service APIs while moving execution to the shared engine."
  use GenServer
  alias ReyCode.LocalEngine.Connection

  def start_link(opts),
    do:
      GenServer.start_link(
        __MODULE__,
        %{
          service: Keyword.fetch!(opts, :service),
          connection: Keyword.get(opts, :connection, Connection),
          registry: Keyword.get(opts, :registry, ReyCode.EventRegistry)
        },
        name: Keyword.fetch!(opts, :name)
      )

  @impl true
  def init(state) do
    {:ok, _} = Registry.register(ReyCode.LocalEngine.ProxyRegistry, self(), state.service)
    {:ok, state}
  end

  @doc "Whether an Engine reference is a client-side transport proxy."
  def remote_engine?(server) do
    case Process.whereis(ReyCode.LocalEngine.ProxyRegistry) && GenServer.whereis(server) do
      pid when is_pid(pid) ->
        Registry.lookup(ReyCode.LocalEngine.ProxyRegistry, pid) == [{pid, :engine}]

      _ ->
        false
    end
  end

  @impl true
  def handle_call(request, _from, state) when request in [:event_registry, :registry],
    do: {:reply, state.registry, state}

  def handle_call(:snapshot, _from, %{service: :catalog} = state),
    do: {:reply, Connection.snapshot(:catalog, state.connection), state}

  def handle_call(request, from, state) do
    Connection.request(state.service, request, from, state.connection)
    {:noreply, state}
  end

  @impl true
  def handle_cast(message, state) do
    Connection.forward_cast(state.service, message, state.connection)
    {:noreply, state}
  end
end
