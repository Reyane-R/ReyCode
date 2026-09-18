defmodule ReyCode.ResourceScopes do
  @moduledoc "Owns bounded resource hubs isolated by canonical workspace and Session."
  use GenServer
  alias ReyCode.Security.CanonicalPath
  alias ReyCode.Tool.Request

  @max_hubs_count 128
  @hubs [ReyCode.ProcessHub, ReyCode.DebuggerHub, ReyCode.EvalHub]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reports whether every global and scoped process/debugger/evaluation hub is idle."
  @spec idle(GenServer.server()) :: :ok | {:error, :resource_work_active}
  def idle(server \\ __MODULE__), do: GenServer.call(server, :idle, 2_000)

  @spec fetch(Request.t(), module()) :: {:ok, pid() | module()} | {:error, term()}
  def fetch(%Request{session_id: nil}, module) when module in @hubs, do: {:ok, module}

  def fetch(%Request{} = request, module) when module in @hubs do
    with {:ok, workspace} <- CanonicalPath.resolve(request.workspace) do
      GenServer.call(__MODULE__, {:hub, {workspace, request.session_id, module}}, 10_000)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{hubs: %{}, monitors: %{}, borrowers: %{}}}

  @impl true
  def handle_call({:hub, key}, {owner, _tag}, state) do
    result =
      case Map.get(state.hubs, key) do
        pid when is_pid(pid) ->
          if Process.alive?(pid),
            do: {:reply, {:ok, pid}, state},
            else: start_hub(key, drop_hub(state, key))

        nil ->
          start_hub(key, state)
      end

    case result do
      {:reply, {:ok, pid}, next} -> {:reply, {:ok, pid}, borrow(next, key, owner)}
      other -> other
    end
  end

  def handle_call(:idle, _from, state) do
    pids =
      @hubs
      |> Enum.map(&Process.whereis/1)
      |> Enum.concat(Map.values(state.hubs))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    idle? =
      pids
      |> Task.async_stream(&hub_idle?/1,
        max_concurrency: 16,
        ordered: false,
        timeout: 100,
        on_timeout: :kill_task
      )
      |> Enum.all?(&(&1 == {:ok, true}))

    reply = if idle?, do: :ok, else: {:error, :resource_work_active}
    {:reply, reply, state}
  end

  defp start_hub({_workspace, _session, module} = key, state) do
    state = if map_size(state.hubs) >= @max_hubs_count, do: reclaim_idle(state), else: state

    if map_size(state.hubs) >= @max_hubs_count do
      {:reply, {:error, :resource_scope_capacity}, state}
    else
      launch_hub(key, module, state)
    end
  end

  defp launch_hub(key, module, state) do
    name = {:via, Registry, {ReyCode.ResourceRegistry, key}}
    spec = Supervisor.child_spec({module, [name: name]}, restart: :temporary)

    case DynamicSupervisor.start_child(ReyCode.ResourceSupervisor, spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        {:reply, {:ok, pid},
         %{
           state
           | hubs: Map.put(state.hubs, key, pid),
             monitors: Map.put(state.monitors, ref, key)
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {key, monitors} = Map.pop(state.monitors, ref)

    {:noreply,
     %{
       state
       | monitors: monitors,
         hubs: Map.delete(state.hubs, key),
         borrowers: Map.delete(state.borrowers, ref)
     }}
  end

  defp borrow(state, key, owner) do
    if Enum.any?(state.borrowers, fn {_ref, value} -> value == {key, owner} end) do
      state
    else
      %{state | borrowers: Map.put(state.borrowers, Process.monitor(owner), {key, owner})}
    end
  end

  defp reclaim_idle(state) do
    Enum.reduce(state.hubs, state, fn {key, pid}, acc ->
      borrowed? =
        Enum.any?(acc.borrowers, fn {_ref, {scope, owner}} ->
          scope == key and Process.alive?(owner)
        end)

      if not borrowed? and hub_idle?(pid) do
        DynamicSupervisor.terminate_child(ReyCode.ResourceSupervisor, pid)
        drop_hub(acc, key)
      else
        acc
      end
    end)
  end

  defp hub_idle?(pid) do
    GenServer.call(pid, :list, 50) |> Enum.all?(&(&1.status != :running))
  catch
    :exit, _ -> not Process.alive?(pid)
  end

  defp drop_hub(state, key) do
    monitors =
      Map.reject(state.monitors, fn {ref, owner} ->
        if owner == key, do: Process.demonitor(ref, [:flush])
        owner == key
      end)

    %{state | hubs: Map.delete(state.hubs, key), monitors: monitors}
  end
end
