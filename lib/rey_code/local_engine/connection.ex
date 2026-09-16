defmodule ReyCode.LocalEngine.Connection do
  @moduledoc "One terminal's reconnecting engine connection. Mutating requests are never replayed."
  use GenServer
  alias ReyCode.LocalEngine.{Launcher, Protocol}
  @poll_ms 100
  @max_pending_count 64

  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: Keyword.get(opts, :name, __MODULE__),
        timeout: 40_000
      )

  def request(service, request, from, server \\ __MODULE__),
    do: GenServer.cast(server, {:request, service, request, from})

  def forward_cast(service, message, server \\ __MODULE__),
    do: GenServer.cast(server, {:forward_cast, service, message})

  def snapshot(service, server \\ __MODULE__), do: GenServer.call(server, {:snapshot, service})

  @impl true
  def init(opts) do
    poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
    true = is_integer(poll_ms) and poll_ms in 1..10_000
    Protocol.load_types()
    path = Keyword.fetch!(opts, :path)
    config = opts |> Keyword.fetch!(:config) |> ReyCode.RuntimeConfig.canonical_paths()
    identity = Protocol.identity(config)

    result =
      Launcher.attach(
        path,
        identity,
        Keyword.get(opts, :launch?, true),
        config
      )

    case result do
      {:ok, socket, snapshots} ->
        :ok = :inet.setopts(socket, active: :once)

        state = %{
          path: path,
          identity: identity,
          socket: socket,
          projection: snapshots.projection,
          catalog: snapshots.catalog,
          remote_generation: snapshots.catalog.generation,
          pending: %{},
          next_id: 0,
          polling: nil,
          registry: Keyword.get(opts, :registry, ReyCode.EventRegistry),
          poll_ms: poll_ms,
          connection_error: nil,
          epoch: 0
        }

        send(self(), {:poll, state.epoch})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:shared_engine_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:snapshot, :engine}, _from, state), do: {:reply, state.projection, state}
  def handle_call({:snapshot, :catalog}, _from, state), do: {:reply, state.catalog, state}

  @impl true
  def handle_cast({:request, :engine, :snapshot, from}, %{socket: nil} = state) do
    GenServer.reply(from, state.projection)
    {:noreply, state}
  end

  def handle_cast({:request, _service, _request, from}, %{socket: nil} = state) do
    GenServer.reply(from, {:error, :engine_disconnected})
    {:noreply, state}
  end

  def handle_cast({:request, service, request, from}, state)
      when map_size(state.pending) >= @max_pending_count do
    {reply, next} = failed_reply(state, request_kind(service, request), :engine_request_capacity)
    GenServer.reply(from, reply)
    {:noreply, next}
  end

  def handle_cast({:request, service, request, from}, state) do
    id = state.next_id + 1

    case Protocol.send(state.socket, {:call, id, service, request}) do
      :ok ->
        timer =
          Process.send_after(
            self(),
            {:request_timeout, id},
            Protocol.request_timeout_ms(service, request)
          )

        {:noreply,
         %{
           state
           | next_id: id,
             pending: Map.put(state.pending, id, {from, timer, request_kind(service, request)})
         }}

      {:error, _reason} ->
        {reply, state} =
          failed_reply(state, request_kind(service, request), :engine_connection_lost)

        GenServer.reply(from, reply)
        {:noreply, disconnect(state)}
    end
  end

  def handle_cast({:forward_cast, service, message}, state) do
    if state.socket, do: Protocol.send(state.socket, {:cast, service, message})
    {:noreply, state}
  end

  @impl true
  def handle_info({:poll, epoch}, %{epoch: epoch, socket: nil} = state), do: {:noreply, state}

  def handle_info({:poll, epoch}, %{epoch: epoch} = state) do
    case Protocol.send(
           state.socket,
           {:poll, {state.projection.sequence, state.remote_generation}}
         ) do
      :ok ->
        timer = Process.send_after(self(), {:poll_timeout, state.socket}, 10_000)
        {:noreply, %{state | polling: timer}}

      _ ->
        {:noreply, disconnect(state)}
    end
  end

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)

    case Protocol.decode(bytes) do
      {:ok, {:snapshots, snapshots}} ->
        cancel_timer(state.polling)
        Process.send_after(self(), {:poll, state.epoch}, state.poll_ms)
        {:noreply, update_snapshots(%{state | polling: nil}, snapshots)}

      {:ok, {:reply, id, result}} ->
        {:noreply, reply_pending(state, id, result)}

      {:ok, :cast_ok} ->
        {:noreply, state}

      _ ->
        {:noreply, disconnect(state)}
    end
  end

  def handle_info({kind, socket}, %{socket: socket} = state)
      when kind in [:tcp_closed, :poll_timeout],
      do: {:noreply, disconnect(state)}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:noreply, disconnect(state)}

  def handle_info({:request_timeout, id}, state),
    do: {:noreply, reply_pending(state, id, {:error, :engine_request_timeout})}

  def handle_info(:reconnect, %{socket: nil} = state) do
    case Launcher.attach(state.path, state.identity, false) do
      {:ok, socket, snapshots} ->
        :ok = :inet.setopts(socket, active: :once)
        state = %{state | socket: socket, connection_error: nil, projection: snapshots.projection}
        state = update_snapshots(state, %{snapshots | projection: nil})
        broadcast(state, :orchestration, {:engine_connection, :connected})
        broadcast(state, :orchestration, {:engine_reconnected, state.projection})
        broadcast(state, :orchestration, {:projection_snapshot, state.projection})
        send(self(), {:poll, state.epoch})
        {:noreply, state}

      {:error, reason} ->
        if state.connection_error != reason do
          broadcast(state, :orchestration, {:engine_connection_error, reason})
        end

        Process.send_after(self(), :reconnect, 500)
        {:noreply, %{state | connection_error: reason}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update_snapshots(state, snapshots) do
    state =
      if state.connection_error == :snapshot_stale do
        broadcast(state, :orchestration, {:engine_connection, :connected})
        %{state | connection_error: nil}
      else
        state
      end

    state =
      if snapshots.projection do
        broadcast(state, :orchestration, {:projection_snapshot, snapshots.projection})
        %{state | projection: snapshots.projection}
      else
        state
      end

    if snapshots.catalog do
      catalog = %{snapshots.catalog | generation: state.catalog.generation + 1}
      broadcast(state, :providers, {:provider_catalog_updated, catalog})
      %{state | catalog: catalog, remote_generation: snapshots.catalog.generation}
    else
      state
    end
  end

  defp reply_pending(state, id, {:engine_result, result, projection}) do
    state = accept_projection(state, projection)
    reply_pending(state, id, result)
  end

  defp reply_pending(state, id, result) do
    state = accept_projection(state, result)

    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, timer, kind}, pending} ->
        cancel_timer(timer)

        {reply, state} =
          case result do
            {:error, reason} -> failed_reply(state, kind, reason)
            _ -> {result, state}
          end

        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp accept_projection(state, result) do
    state =
      case result do
        %ReyCode.Orchestration.Projection{sequence: sequence}
        when sequence > state.projection.sequence ->
          broadcast(state, :orchestration, {:projection_snapshot, result})
          %{state | projection: result}

        _ ->
          state
      end

    state
  end

  defp request_kind(:engine, :snapshot), do: :snapshot
  defp request_kind(_service, _request), do: :command

  defp failed_reply(state, :snapshot, _reason) do
    broadcast(state, :orchestration, {:engine_connection_error, :snapshot_stale})
    {state.projection, %{state | connection_error: :snapshot_stale}}
  end

  defp failed_reply(state, :command, reason), do: {{:error, reason}, state}

  defp disconnect(%{socket: nil} = state), do: state

  defp disconnect(state) do
    :gen_tcp.close(state.socket)
    cancel_timer(state.polling)

    Enum.each(state.pending, fn {_id, {from, timer, kind}} ->
      cancel_timer(timer)
      {reply, _state} = failed_reply(state, kind, :engine_connection_lost)
      GenServer.reply(from, reply)
    end)

    broadcast(state, :orchestration, {:engine_connection, :disconnected})
    Process.send_after(self(), :reconnect, 500)
    %{state | socket: nil, pending: %{}, polling: nil, epoch: state.epoch + 1}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp broadcast(state, key, message),
    do:
      Registry.dispatch(state.registry, key, fn entries ->
        Enum.each(entries, fn {pid, _} -> send(pid, message) end)
      end)

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end
end
