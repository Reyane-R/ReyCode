defmodule ReyCode.Provider.Catalog do
  @moduledoc """
  Discovers provider capabilities and resolves frozen ProviderRuntimes.

  Every provider and API profile is probed independently behind its own
  supervised task and its own timeout: one hung or failing probe never
  blocks or poisons unrelated providers. Results publish as soon as they
  settle, tagged with their probe-round generation so results from
  superseded rounds are ignored. Discovery is transient, bounded, and
  retryable; it never enters durable Projection state.
  `resolve_when_ready/3` replies when the requested provider settles rather
  than when a whole refresh round ends, and therefore uses an intentional
  infinite call timeout; task/probe policy bounds the physical work.
  Missing, checking, unavailable, and invalid-model states return stable
  tagged reasons.
  """

  use GenServer

  alias ReyCode.Provider.Catalog.Snapshot
  alias ReyCode.Provider.OpenAICompatible
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

  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @doc """
  Subscribes the caller to catalog broadcasts and returns the current view.

  The returned snapshot carries the `generation` needed to continue the
  stream monotonically. A broadcast dispatched after registration but before
  this reply can still be queued ahead of it in the caller's mailbox, so
  consumers must ignore snapshots whose generation is at or below the one
  they already hold; generations strictly increase per broadcast.
  """
  @spec subscribe(GenServer.server()) :: Snapshot.t()
  def subscribe(server \\ __MODULE__) do
    registry = GenServer.call(server, :registry)
    ensure_registered(registry, :providers)

    snapshot(server)
  end

  # Duplicate registries append another entry when the same pid registers
  # twice, so re-subscription checks the existing registration instead.
  defp ensure_registered(registry, key) do
    unless Enum.any?(Registry.lookup(registry, key), fn {pid, _value} -> pid == self() end) do
      {:ok, _pid} = Registry.register(registry, key, nil)
    end

    :ok
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

    providers =
      ProviderRegistry.descriptors(config)
      |> Map.new(fn descriptor -> {descriptor.id, pending_provider(descriptor)} end)
      |> maybe_add_simulator(Keyword.put_new(opts, :config, config))

    state = %{
      providers: providers,
      registry: Keyword.get(opts, :registry, ReyCode.EventRegistry),
      task_supervisor: Keyword.get(opts, :task_supervisor, ReyCode.ProviderTaskSupervisor),
      config: config,
      discovery?: Keyword.get(opts, :discovery?, config.providers.discovery?),
      probe_targets: probe_targets(opts, profiles, config),
      refresh_interval: Keyword.get(opts, :refresh_interval, @refresh_interval),
      retry_interval: Keyword.get(opts, :retry_interval, @retry_interval),
      probe_timeout: Keyword.get(opts, :probe_timeout, @probe_timeout),
      generation: 0,
      probes: %{},
      refresh_timer: nil,
      awaiters: []
    }

    if state.discovery? do
      {:ok, state, {:continue, :refresh}}
    else
      {:ok, update_status(state, :unchecked)}
    end
  end

  # API profiles are independent failure domains. Tests can inject discovery
  # per profile without introducing a second provider execution protocol.
  defp probe_targets(opts, profiles, config) do
    discover =
      Keyword.get(opts, :discover, fn profile ->
        OpenAICompatible.discover(profile, policy: config.open_ai)
      end)

    Enum.map(profiles, fn profile -> {profile.id, fn -> discover.(profile) end} end)
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, start_probe(state)}

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, build_snapshot(state), state}

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

  # A settled probe publishes only its own provider's entry, so fast
  # providers become resolvable without waiting for slower siblings.
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case take_probe(state, ref) do
      {probe, state} ->
        Process.demonitor(ref, [:flush])

        {:noreply,
         settle_probe(state, probe, fn providers ->
           merge_result(providers, probe.key, result, state.config)
         end)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case take_probe(state, ref) do
      {probe, state} ->
        message = "provider discovery failed: #{inspect(reason)}"

        {:noreply,
         settle_probe(state, probe, fn providers ->
           fail_providers(providers, probe.key, state, message)
         end)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:probe_timeout, ref}, state) do
    case take_probe(state, ref) do
      {probe, state} ->
        Task.shutdown(probe.task, :brutal_kill)
        message = "provider discovery timed out"

        {:noreply,
         settle_probe(state, probe, fn providers ->
           fail_providers(providers, probe.key, state, message)
         end)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:scheduled_refresh, token}, %{refresh_timer: {_timer, token}} = state) do
    {:noreply, start_probe(%{state | refresh_timer: nil})}
  end

  # Results and timer messages from cancelled or superseded probes are
  # intentionally ignored.
  def handle_info(_, state), do: {:noreply, state}

  # A new round never overlaps an in-flight one; results racing a finished
  # or superseded round are dropped because their probe entry is gone.
  defp start_probe(%{discovery?: false} = state), do: state
  defp start_probe(%{probes: probes} = state) when map_size(probes) > 0, do: state

  defp start_probe(state) do
    generation = state.generation + 1

    {probe_pairs, providers} =
      Enum.map_reduce(state.probe_targets, state.providers, fn {key, discover}, acc ->
        task = Task.Supervisor.async_nolink(state.task_supervisor, discover)

        timer = Process.send_after(self(), {:probe_timeout, task.ref}, state.probe_timeout)

        probe = %{key: key, timer: timer, generation: generation, task: task}

        {{task.ref, probe}, Map.put(acc, key, checking_entry(acc[key], key))}
      end)

    next =
      state
      |> Map.put(:generation, generation)
      |> Map.put(:probes, Map.new(probe_pairs))
      |> Map.put(:providers, providers)
      |> broadcast()

    next
  end

  # Refresh preserves the last known models while a profile is checking.
  defp checking_entry(nil, _key), do: nil

  defp checking_entry(entry, _key), do: %{entry | status: :checking, error: nil}

  defp take_probe(state, ref) do
    case Map.pop(state.probes, ref) do
      {nil, _probes} -> nil
      {probe, probes} -> {probe, %{state | probes: probes}}
    end
  end

  # The updater receives the current providers so each settlement publishes
  # exactly one generation-consistent transition.
  defp settle_probe(state, probe, update) do
    providers = update.(state.providers)

    settled_keys = [probe.key]

    state =
      state
      |> Map.put(:providers, providers)
      |> reply_awaiters_for(settled_keys)
      |> broadcast()

    complete_round_if_finished(state)
  end

  defp merge_result(providers, id, result, config) do
    case normalize_api_result(id, result, config) do
      nil -> providers
      entry -> Map.put(providers, id, entry)
    end
  end

  # Timeouts and crashes mark only the failed target's providers; healthy
  # entries keep their last published status.
  defp fail_providers(providers, key, _state, message) do
    Map.update!(providers, key, fn entry -> %{entry | status: :error, error: message} end)
  end

  defp complete_round_if_finished(%{probes: probes} = state) when map_size(probes) == 0 do
    delay =
      if refresh_retry?(state.providers),
        do: state.retry_interval,
        else: state.refresh_interval

    schedule_refresh(state, delay)
  end

  defp complete_round_if_finished(state), do: state

  @optional_local_profiles MapSet.new([:ollama, :lmstudio])

  defp refresh_retry?(providers) do
    Enum.any?(providers, fn
      {:simulator, _entry} ->
        false

      {key, %{status: status}} when status in [:error, :missing] ->
        not MapSet.member?(@optional_local_profiles, key)

      _other ->
        false
    end)
  end

  defp normalize_api_result(id, {:ok, discovery}, config) do
    case ProviderRegistry.descriptor(id, config) do
      nil -> nil
      descriptor -> api_entry(descriptor, discovery)
    end
  end

  defp normalize_api_result(id, result, config) do
    case ProviderRegistry.descriptor(id, config) do
      nil ->
        nil

      descriptor ->
        reason =
          case result do
            {:error, reason} -> reason
            other -> other
          end

        api_entry(descriptor, %{status: :error, error: format_reason(reason)})
    end
  end

  defp api_entry(descriptor, discovery) do
    %{
      id: descriptor.id,
      name: descriptor.name,
      description: descriptor.description,
      module: descriptor.module,
      status: Map.get(discovery, :status, :error),
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
      credential_count: 0,
      models: [],
      error: nil,
      checked_at: nil
    }
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

  # Replies only the awaiters of the provider keys that just settled, so a
  # slow sibling probe cannot hold another provider's resolution hostage.
  defp reply_awaiters_for(state, settled_keys) do
    {replied, waiting} =
      Enum.split_with(state.awaiters, fn {_from, key, _model} -> key in settled_keys end)

    Enum.each(replied, fn {from, key, model} ->
      GenServer.reply(from, resolve_entry(key, state.providers[key], model, state))
    end)

    %{state | awaiters: waiting}
  end

  # Every broadcast publishes a strictly higher generation so consumers can
  # order snapshots without trusting wall-clock timestamps.
  defp broadcast(%{generation: generation} = state) do
    snapshot = %Snapshot{generation: generation + 1, providers: state.providers}

    Registry.dispatch(state.registry, :providers, fn entries ->
      Enum.each(entries, fn {pid, _value} ->
        send(pid, {:provider_catalog_updated, snapshot})
      end)
    end)

    %{state | generation: generation + 1}
  end

  defp build_snapshot(%{generation: generation, providers: providers}),
    do: %Snapshot{generation: generation, providers: providers}

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
      config: runtime_policy(entry.module, state.config),
      workspace_policy: state.config.workspace,
      models: Map.get(entry, :models, []),
      status: entry.status
    }
  end

  defp maybe_add_simulator(providers, opts) do
    allowed? =
      Keyword.get_lazy(opts, :allow_simulator?, fn ->
        case Keyword.get(opts, :config) do
          %RuntimeConfig{} = config -> config.providers.allow_simulator?
          _other -> false
        end
      end)

    if allowed? do
      Map.put(providers, :simulator, %{
        id: :simulator,
        name: ProviderRegistry.display_name(:simulator),
        description: "test-only deterministic provider",
        module: ReyCode.Provider.Simulator,
        status: :configured,
        checked_at: DateTime.utc_now()
      })
    else
      providers
    end
  end

  defp runtime_policy(ReyCode.Provider.OpenAICompatible, config), do: config.open_ai

  defp runtime_policy(ReyCode.Provider.Simulator, config),
    do: RuntimeConfig.simulator_policy(config)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
