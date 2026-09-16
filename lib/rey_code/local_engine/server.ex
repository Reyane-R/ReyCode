defmodule ReyCode.LocalEngine.Server do
  @moduledoc "Private Unix socket endpoint for the single durable engine."
  use GenServer
  alias ReyCode.LocalEngine.Protocol
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.Catalog
  alias ReyCode.VerifiedChange.Interactive

  @max_clients_count 32
  @idle_timeout_ms 60_000
  @engine_operations %{
    create_blank_session: 3,
    ensure_workspace_session: 2,
    create_session: 3,
    fork_session: 3,
    run_owner_command: 3,
    add_task_participant: 4,
    post_message: 4,
    steer_turn: 3,
    dequeue_latest_follow_up: 2,
    retry_turn: 2,
    delegate_task: 4,
    strategy_workspace: 2,
    advise_strategy: 5,
    challenge: 5,
    answer_question: 4,
    resolve_merge: 3,
    cancel_turn: 3,
    configure_participants: 5,
    configure_participant_tier: 4,
    configure_squad_roles: 5,
    add_squad_directive: 3,
    resolve_gate: 6,
    resolve_tool_run: 4,
    cancel_verified_change: 2,
    verified_change_status: 2,
    resolve_verified_change: 5,
    reconcile_verified_change: 4
  }
  @services %{
    engine: Engine,
    catalog: Catalog,
    memory: ReyCode.Memory.Store,
    credentials: ReyCode.Provider.Credentials
  }

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Protocol.load_types()
    path = Keyword.fetch!(opts, :path)
    identity = Protocol.identity(Keyword.fetch!(opts, :config))

    with :ok <- prepare_socket(path),
         {:ok, listener} <-
           :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | Protocol.socket_options()]),
         :ok <- File.chmod(path, 0o600) do
      state = %{
        listener: listener,
        path: path,
        identity: identity,
        clients: %{},
        services: Keyword.get(opts, :services, @services)
      }

      send(self(), :accept)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp prepare_socket(path) do
    with true <- byte_size(path) <= 100,
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, %{type: :directory}} <- File.lstat(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700) do
      case Protocol.connect(path) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          {:error, :engine_already_running}

        {:error, :enoent} ->
          :ok

        {:error, :econnrefused} ->
          File.rm(path)

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :engine_socket_path_too_long}
      {:ok, _stat} -> {:error, :unsafe_engine_directory}
      error -> error
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listener, 50) do
      {:ok, socket} ->
        state = admit(socket, state)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | clients: Map.delete(state.clients, ref)}}

  defp admit(socket, state) when map_size(state.clients) >= @max_clients_count do
    Protocol.send(socket, {:error, :engine_client_capacity})
    :gen_tcp.close(socket)
    state
  end

  defp admit(socket, state) do
    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :ready -> serve(socket, state.identity, state.services)
        after
          5_000 -> :gen_tcp.close(socket)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :ready)
    %{state | clients: Map.put(state.clients, ref, pid)}
  end

  defp serve(socket, identity, services) do
    try do
      case Protocol.recv(socket) do
        {:ok, {:hello, ^identity}} ->
          :ok = Protocol.send(socket, {:ok, snapshots(services, {-1, -1})})
          serve_calls(socket, services)

        {:ok, {:hello, other}} ->
          Protocol.send(socket, {:error, incompatibility(identity, other)})

        {:ok, {:control, :status}} ->
          Protocol.send(socket, {:ok, identity})

        {:ok, {:control, :stop}} ->
          Protocol.send(socket, :ok)
          :init.stop()

        _ ->
          :ok
      end
    after
      :gen_tcp.close(socket)
    end
  catch
    _kind, _reason -> :ok
  end

  defp incompatibility(identity, other) when is_map(other) do
    cond do
      other[:protocol] != identity.protocol ->
        :engine_protocol_mismatch

      other[:storage] != identity.storage ->
        :engine_storage_mismatch

      other[:build] != identity.build or other[:version] != identity.version ->
        {:engine_build_mismatch, identity.version}

      true ->
        keys = Map.keys(identity.policy_details) ++ Map.keys(Map.get(other, :policy_details, %{}))

        changed =
          keys
          |> Enum.uniq()
          |> Enum.filter(&(identity.policy_details[&1] != get_in(other, [:policy_details, &1])))
          |> Enum.sort()

        {:engine_configuration_mismatch, changed}
    end
  end

  defp incompatibility(_identity, _other), do: :invalid_engine_handshake

  defp serve_calls(socket, services) do
    :ok = :inet.setopts(socket, active: :once)
    serve_calls(socket, services, %{})
  end

  defp serve_calls(socket, services, pending) do
    receive do
      {:tcp, ^socket, bytes} ->
        with {:ok, request} <- Protocol.decode(bytes),
             {:ok, pending} <- answer(socket, request, services, pending),
             :ok <- :inet.setopts(socket, active: :once) do
          serve_calls(socket, services, pending)
        end

      {:rpc_result, id, result} ->
        {ref, pending} = Map.pop(pending, id)
        if ref, do: Process.demonitor(ref, [:flush])

        with :ok <- Protocol.send(socket, {:reply, id, result}),
             do: serve_calls(socket, services, pending)

      {:DOWN, ref, :process, _pid, _reason} ->
        case Enum.find(pending, fn {_id, monitor} -> monitor == ref end) do
          {id, _} ->
            Protocol.send(socket, {:reply, id, {:error, :engine_operation_failed}})
            serve_calls(socket, services, Map.delete(pending, id))

          nil ->
            serve_calls(socket, services, pending)
        end

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok
    after
      @idle_timeout_ms -> :ok
    end
  end

  defp answer(socket, {:poll, versions}, services, pending) do
    with :ok <- Protocol.send(socket, {:snapshots, snapshots(services, versions)}),
         do: {:ok, pending}
  end

  defp answer(socket, {:call, id, service, request}, services, pending)
       when is_integer(id) and id > 0 do
    if map_size(pending) >= 32 or Map.has_key?(pending, id) do
      Protocol.send(socket, {:reply, id, {:error, :engine_request_capacity}})
      {:ok, pending}
    else
      owner = self()

      task =
        Task.Supervisor.start_child(ReyCode.IPCTaskSupervisor, fn ->
          send(owner, {:rpc_result, id, safe_dispatch(service, request, services)})
        end)

      case task do
        {:ok, pid} ->
          {:ok, Map.put(pending, id, Process.monitor(pid))}

        {:error, _} ->
          Protocol.send(socket, {:reply, id, {:error, :engine_request_capacity}})
          {:ok, pending}
      end
    end
  end

  defp answer(socket, {:cast, :catalog, :refresh}, services, pending) do
    GenServer.cast(services.catalog, :refresh)
    with :ok <- Protocol.send(socket, :cast_ok), do: {:ok, pending}
  end

  defp answer(_socket, _request, _services, _pending), do: {:error, :invalid_request}

  defp safe_dispatch(service, request, services) do
    dispatch(service, request, services)
  rescue
    _ -> {:error, :engine_operation_failed}
  catch
    _kind, _reason -> {:error, :engine_operation_failed}
  end

  defp snapshots(services, {sequence, generation}) do
    projection = GenServer.call(services.engine, :snapshot)
    catalog = GenServer.call(services.catalog, :snapshot)

    %{
      projection: if(projection.sequence > sequence, do: projection),
      catalog: if(catalog.generation != generation, do: catalog)
    }
  end

  defp dispatch(:engine, {:ui_start_verified_change, session, options}, services),
    do: Interactive.start_receipt(session, options, services.engine)

  defp dispatch(:engine, {:ui_verified_change_run, options}, services),
    do: ReyCode.VerifiedChange.run(options, services.engine)

  defp dispatch(:engine, request, services) when request in [:snapshot, :check_policy],
    do: GenServer.call(services.engine, request)

  defp dispatch(:engine, request, services)
       when is_tuple(request) and tuple_size(request) > 0 and
              is_map_key(@engine_operations, elem(request, 0)) do
    if tuple_size(request) == Map.fetch!(@engine_operations, elem(request, 0)),
      do: GenServer.call(services.engine, {:client_request, request}, 30_000),
      else: {:error, :invalid_engine_request}
  end

  defp dispatch(:catalog, request, services)
       when is_tuple(request) and tuple_size(request) == 3 and
              elem(request, 0) in [:resolve, :resolve_when_ready],
       do: GenServer.call(services.catalog, request, 20_000)

  defp dispatch(:credentials, {action, key} = request, services)
       when action in [:fetch, :remove] and is_binary(key) do
    if credential_name?(key),
      do: GenServer.call(services.credentials, request),
      else: {:error, :invalid_credential_name}
  end

  defp dispatch(:credentials, {:remember, key, value, persist?} = request, services)
       when is_binary(key) and is_binary(value) and is_boolean(persist?) do
    if credential_name?(key) and String.valid?(value) and not String.contains?(value, <<0>>),
      do: GenServer.call(services.credentials, request),
      else: {:error, :invalid_credential}
  end

  defp dispatch(:memory, request, services) do
    if valid_memory_request?(request),
      do: GenServer.call(services.memory, request),
      else: {:error, :invalid_memory_request}
  end

  defp dispatch(_service, _request, _services), do: {:error, :unsupported_engine_operation}

  defp valid_memory_request?({:record, project, kind, key, value, tags}),
    do: Enum.all?([project, kind, key, value], &is_binary/1) and strings?(tags)

  defp valid_memory_request?({action, project, key, value, tags})
       when action in [:retain, :learn],
       do: Enum.all?([project, key, value], &is_binary/1) and strings?(tags)

  defp valid_memory_request?({:list, project, kinds, count}),
    do: is_binary(project) and strings?(kinds) and is_integer(count) and count > 0

  defp valid_memory_request?({:recall, project, query, count}),
    do: is_binary(project) and is_binary(query) and is_integer(count) and count > 0

  defp valid_memory_request?({:forget, project, key}), do: is_binary(project) and is_binary(key)
  defp valid_memory_request?({:reflect, project}), do: is_binary(project)
  defp valid_memory_request?(_request), do: false

  defp strings?(values),
    do: is_list(values) and length(values) <= 100 and Enum.all?(values, &is_binary/1)

  defp credential_name?(key),
    do: key != "" and String.valid?(key) and not String.contains?(key, [<<0>>, "="])

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.clients, fn {_ref, pid} -> Process.exit(pid, :shutdown) end)
    File.rm(state.path)
    :ok
  end
end
