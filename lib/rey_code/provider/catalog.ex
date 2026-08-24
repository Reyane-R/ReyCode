defmodule ReyCode.Provider.Catalog do
  @moduledoc "Discovers provider runtimes and publishes their transient availability."

  use GenServer

  alias ReyCode.Provider.Registry, as: ProviderRegistry
  alias ReyCode.Provider.Runtime
  alias ReyCode.RuntimeConfig

  @refresh_interval :timer.minutes(5)
  @retry_interval :timer.seconds(15)
  @probe_timeout :timer.seconds(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  def subscribe(server \\ __MODULE__) do
    registry = GenServer.call(server, :registry)

    case Registry.register(registry, :providers, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end

    snapshot(server)
  end

  @spec resolve(atom() | String.t(), String.t() | nil, GenServer.server()) ::
          {:ok, Runtime.t()} | {:error, atom()}
  def resolve(provider, model, server \\ __MODULE__) do
    GenServer.call(server, {:resolve, provider, model})
  end

  @spec resolve_when_ready(atom() | String.t(), String.t() | nil, GenServer.server()) ::
          {:ok, Runtime.t()} | {:error, atom()}
  def resolve_when_ready(provider, model, server \\ __MODULE__) do
    GenServer.call(server, {:resolve_when_ready, provider, model}, :infinity)
  end

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &RuntimeConfig.fresh/0)
    profiles = ProviderRegistry.api_profiles(config)
    opencode_module = ProviderRegistry.descriptor(:opencode, config).module

    providers =
      ProviderRegistry.descriptors(config)
      |> Map.new(fn descriptor -> {descriptor.id, pending_provider(descriptor)} end)
      |> maybe_add_simulator(Keyword.put_new(opts, :config, config))

    state = %{
      providers: providers,
      profiles: profiles,
      registry: Keyword.get(opts, :registry, ReyCode.EventRegistry),
      task_supervisor: Keyword.get(opts, :task_supervisor, ReyCode.ProviderTaskSupervisor),
      config: config,
      discovery?:
        Keyword.get_lazy(opts, :discovery?, fn ->
          RuntimeConfig.policy(config, :provider_discovery, true)
        end),
      discover: Keyword.get(opts, :discover, fn -> opencode_module.discover(config: config) end),
      api_discover:
        Keyword.get(opts, :api_discover, fn -> discover_api_profiles(profiles, config) end),
      refresh_interval: Keyword.get(opts, :refresh_interval, @refresh_interval),
      retry_interval: Keyword.get(opts, :retry_interval, @retry_interval),
      probe_timeout: Keyword.get(opts, :probe_timeout, @probe_timeout),
      task: nil,
      probe_timer: nil,
      refresh_timer: nil,
      awaiters: []
    }

    if state.discovery? do
      {:ok, state, {:continue, :refresh}}
    else
      {:ok, update_status(state, :unchecked)}
    end
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, start_probe(state)}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.providers, state}
  def handle_call(:registry, _from, state), do: {:reply, state.registry, state}

  def handle_call({:resolve, provider, model}, _from, state) do
    key = provider_key(state.config, provider)
    entry = state.providers[key]
    {:reply, resolve_entry(key, entry, model, state), state}
  end

  def handle_call({:resolve_when_ready, provider, model}, from, state) do
    key = provider_key(state.config, provider)

    if get_in(state.providers, [key, :status]) == :checking do
      {:noreply, %{state | awaiters: [{from, key, model} | state.awaiters]}}
    else
      {:reply, resolve_entry(key, state.providers[key], model, state), state}
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    state = cancel_refresh_timer(state)
    {:noreply, start_probe(state)}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    opencode_entry = normalize_open_code(result[:opencode])

    providers =
      state.providers
      |> put_in([:opencode], opencode_entry)
      |> merge_api_results(result[:api] || %{}, state.config)

    delay =
      if refresh_retry?(providers),
        do: state.retry_interval,
        else: state.refresh_interval

    next =
      state
      |> cancel_probe_timer()
      |> Map.put(:task, nil)
      |> Map.put(:providers, providers)
      |> schedule_refresh(delay)
      |> reply_awaiters()

    broadcast(next)
    {:noreply, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    next = finish_failure(state, "provider discovery failed: #{inspect(reason)}")
    {:noreply, next}
  end

  def handle_info({:probe_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    next = finish_failure(%{state | task: nil, probe_timer: nil}, "provider discovery timed out")
    {:noreply, next}
  end

  def handle_info({:scheduled_refresh, token}, %{refresh_timer: {_timer, token}} = state) do
    {:noreply, start_probe(%{state | refresh_timer: nil})}
  end

  # Results and timer messages from cancelled or completed probes are intentionally ignored.
  def handle_info(_, state), do: {:noreply, state}

  defp start_probe(%{discovery?: false} = state), do: state
  defp start_probe(%{task: %Task{}} = state), do: state

  defp start_probe(state) do
    discover = state.discover
    api_discover = state.api_discover

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        %{opencode: discover.(), api: api_discover.()}
      end)

    timer = Process.send_after(self(), {:probe_timeout, task.ref}, state.probe_timeout)

    next =
      state
      |> update_status(:checking)
      |> Map.put(:task, task)
      |> Map.put(:probe_timer, timer)

    broadcast(next)
    next
  end

  defp finish_failure(state, message) do
    now = DateTime.utc_now()

    providers =
      Map.new(state.providers, fn
        {:simulator, entry} -> {:simulator, entry}
        {key, entry} -> {key, %{entry | status: :error, error: message, checked_at: now}}
      end)

    next =
      state
      |> cancel_probe_timer()
      |> Map.put(:task, nil)
      |> Map.put(:providers, providers)
      |> schedule_refresh(state.retry_interval)
      |> reply_awaiters()

    broadcast(next)
    next
  end

  defp merge_api_results(providers, api_results, config) do
    Enum.reduce(api_results, providers, fn {id, result}, acc ->
      case normalize_api_result(id, result, config) do
        nil -> acc
        entry -> put_in(acc, [id], entry)
      end
    end)
  end

  defp refresh_retry?(providers) do
    Enum.any?(providers, fn
      {:simulator, _entry} -> false
      {_key, %{status: status}} when status in [:error, :missing] -> true
      _other -> false
    end)
  end

  defp normalize_open_code({:ok, discovery}) do
    status = if(discovery.models == [], do: :available, else: :configured)
    descriptor = ProviderRegistry.descriptor(:opencode)

    %{
      id: descriptor.id,
      name: descriptor.name,
      description: descriptor.description,
      module: descriptor.module,
      status: status,
      version: discovery.version,
      executable: discovery.executable,
      credential_count: discovery.credential_count,
      models: discovery.models,
      error: nil,
      checked_at: DateTime.utc_now()
    }
  end

  defp normalize_open_code({:error, :missing_executable}) do
    %{
      pending_open_code()
      | status: :missing,
        error: "opencode executable not found",
        checked_at: DateTime.utc_now()
    }
  end

  defp normalize_open_code({:error, reason}) do
    %{
      pending_open_code()
      | status: :error,
        error: format_reason(reason),
        checked_at: DateTime.utc_now()
    }
  end

  defp normalize_open_code(other), do: normalize_open_code({:error, inspect(other)})

  defp normalize_api_result(id, {:ok, discovery}, config) do
    case ProviderRegistry.descriptor(id, config) do
      %{id: :opencode} -> nil
      nil -> nil
      descriptor -> api_entry(descriptor, discovery)
    end
  end

  defp normalize_api_result(_id, _result, _config), do: nil

  defp api_entry(descriptor, discovery) do
    %{
      id: descriptor.id,
      name: descriptor.name,
      description: descriptor.description,
      module: descriptor.module,
      status: Map.get(discovery, :status, :error),
      version: nil,
      executable: nil,
      credential_count: Map.get(discovery, :credential_count, 0),
      models: Map.get(discovery, :models, []),
      error: Map.get(discovery, :error),
      checked_at: DateTime.utc_now()
    }
  end

  defp pending_provider(descriptor) do
    %{
      id: descriptor.id,
      name: descriptor.name,
      description: descriptor.description,
      module: descriptor.module,
      status: :checking,
      version: nil,
      executable: nil,
      credential_count: 0,
      models: [],
      error: nil,
      checked_at: nil
    }
  end

  defp discover_api_profiles(profiles, config) do
    Map.new(profiles, fn profile ->
      module = ProviderRegistry.descriptor(profile.id, config).module
      {profile.id, module.discover(profile, config: config)}
    end)
  end

  defp pending_open_code do
    ProviderRegistry.descriptor(:opencode) |> pending_provider()
  end

  defp update_status(state, status) do
    providers =
      Map.new(state.providers, fn
        {:simulator, entry} -> {:simulator, entry}
        {key, entry} -> {key, %{entry | status: status, error: nil}}
      end)

    %{state | providers: providers}
  end

  defp schedule_refresh(state, delay) do
    state = cancel_refresh_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:scheduled_refresh, token}, delay)
    %{state | refresh_timer: {timer, token}}
  end

  defp cancel_refresh_timer(%{refresh_timer: nil} = state), do: state

  defp cancel_refresh_timer(%{refresh_timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | refresh_timer: nil}
  end

  defp cancel_probe_timer(%{probe_timer: nil} = state), do: state

  defp cancel_probe_timer(%{probe_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | probe_timer: nil}
  end

  defp reply_awaiters(state) do
    Enum.each(state.awaiters, fn {from, key, model} ->
      GenServer.reply(from, resolve_entry(key, state.providers[key], model, state))
    end)

    %{state | awaiters: []}
  end

  defp broadcast(state) do
    Registry.dispatch(state.registry, :providers, fn entries ->
      Enum.each(entries, fn {pid, _value} ->
        send(pid, {:provider_catalog_updated, state.providers})
      end)
    end)
  end

  defp provider_key(config, value), do: ProviderRegistry.normalize_provider_id(value, config)

  defp resolve_entry(_key, nil, _model, _state), do: {:error, :unknown_provider}

  defp resolve_entry(_key, %{status: :checking}, _model, _state), do: {:error, :provider_checking}

  defp resolve_entry(_key, %{status: status}, _model, _state)
       when status in [:missing, :available, :unchecked, :error],
       do: {:error, status}

  defp resolve_entry(:simulator, entry, _model, state),
    do: {:ok, runtime_from_entry(entry, state)}

  defp resolve_entry(_key, _entry, model, _state) when model in [nil, ""],
    do: {:error, :model_required}

  defp resolve_entry(_key, %{models: models} = entry, model, state) do
    if model in models,
      do: {:ok, runtime_from_entry(entry, state)},
      else: {:error, :model_unavailable}
  end

  defp runtime_from_entry(entry, state) do
    %Runtime{
      module: entry.module,
      provider_id: entry.id,
      executable: Map.get(entry, :executable),
      version: Map.get(entry, :version),
      config: state.config,
      models: Map.get(entry, :models, []),
      status: entry.status
    }
  end

  defp maybe_add_simulator(providers, opts) do
    allowed? =
      Keyword.get_lazy(opts, :allow_simulator?, fn ->
        RuntimeConfig.policy(Keyword.get(opts, :config), :allow_simulator_provider, false)
      end)

    if allowed? do
      Map.put(providers, :simulator, %{
        id: :simulator,
        name: ProviderRegistry.display_name(:simulator),
        description: "test-only deterministic provider",
        module: ReyCode.Provider.Simulator,
        status: :configured,
        version: "test only",
        credential_count: 0,
        models: [],
        error: nil,
        checked_at: DateTime.utc_now()
      })
    else
      providers
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
