defmodule ReyCode.SubscriptionMonotonicTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.Catalog
  alias ReyCode.Provider.Catalog.Snapshot
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.State

  defmodule StaleBroadcastEngine do
    @moduledoc false

    use GenServer

    # Reproduces the subscribe race deterministically: the older projection is
    # dispatched while :snapshot is handled, so it queues ahead of the newer
    # baseline reply in the subscriber's mailbox.
    def start_link(registry), do: GenServer.start_link(__MODULE__, registry)

    def init(registry), do: {:ok, registry}

    def handle_call(:event_registry, _from, registry), do: {:reply, registry, registry}

    def handle_call(:snapshot, _from, registry) do
      broadcast(registry, %{sequence: 1})
      {:reply, %{sequence: 2, rooms: %{}, room_order: []}, registry}
    end

    def handle_call(:broadcast_next, _from, registry) do
      broadcast(registry, %{sequence: 3})
      {:reply, :ok, registry}
    end

    defp broadcast(registry, projection) do
      Registry.dispatch(registry, :orchestration, fn entries ->
        Enum.each(entries, fn {pid, _value} -> send(pid, {:projection_snapshot, projection}) end)
      end)
    end
  end

  defmodule StaleBroadcastCatalog do
    @moduledoc false

    use GenServer

    def start_link(registry), do: GenServer.start_link(__MODULE__, registry)

    def init(registry), do: {:ok, registry}

    def handle_call(:registry, _from, registry), do: {:reply, registry, registry}

    def handle_call(:snapshot, _from, registry) do
      broadcast(registry, 1, %{})
      {:reply, %Snapshot{generation: 2, providers: %{}}, registry}
    end

    def handle_call(:broadcast_next, _from, registry) do
      broadcast(registry, 3, %{omp: %{status: :configured}})
      {:reply, :ok, registry}
    end

    defp broadcast(registry, generation, providers) do
      snapshot = %Snapshot{generation: generation, providers: providers}

      Registry.dispatch(registry, :providers, fn entries ->
        Enum.each(entries, fn {pid, _value} ->
          send(pid, {:provider_catalog_updated, snapshot})
        end)
      end)
    end
  end

  describe "engine subscription stream" do
    test "a stale notification queued before the baseline never regresses the TUI" do
      registry = :"monotonic_events_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      engine = start_supervised!({StaleBroadcastEngine, registry})

      baseline = Engine.subscribe(engine)
      assert %{sequence: 2} = baseline

      term = mounted_term(%{projection: baseline})

      stale = %{sequence: 1, rooms: %{"room-stale" => :sentinel}, room_order: ["room-stale"]}
      assert ^term = State.projection_updated(term, stale)
    end

    test "wait helpers skip notifications at or below the subscribed baseline" do
      registry = :"monotonic_events_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      engine = start_supervised!({StaleBroadcastEngine, registry})

      # Queue a stale notification and then a fresh one before waiting, so
      # the helper must skip everything at or below its new baseline.
      assert %{sequence: 2} = Engine.subscribe(engine)
      assert :ok = GenServer.call(engine, :broadcast_next)

      assert %{sequence: 3} =
               Wait.projection(engine, fn
                 %{sequence: 3} = projection -> projection
                 _other -> nil
               end)
    end
  end

  describe "catalog subscription stream" do
    test "generations strictly increase and stale snapshots never regress the TUI" do
      registry = :"monotonic_providers_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      catalog = start_supervised!({StaleBroadcastCatalog, registry})

      assert %Snapshot{generation: 2} = baseline = Catalog.subscribe(catalog)

      term =
        mounted_term(%{
          providers: baseline.providers,
          providers_generation: baseline.generation
        })

      stale = %Snapshot{generation: 1, providers: %{"stale" => :sentinel}}
      assert ^term = State.providers_updated(term, stale)

      # Queue a newer generation before waiting so the helper must skip the
      # stale snapshot it receives ahead of it.
      assert :ok = GenServer.call(catalog, :broadcast_next)

      assert %{omp: %{status: :configured}} =
               Wait.catalog(catalog, fn
                 %{omp: %{status: :configured}} = providers -> providers
                 _other -> nil
               end)
    end

    test "re-subscribing does not duplicate the registration" do
      registry = :"monotonic_providers_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      catalog = start_supervised!({StaleBroadcastCatalog, registry})

      assert %Snapshot{} = Catalog.subscribe(catalog)
      assert %Snapshot{} = Catalog.subscribe(catalog)
      drain_catalog_broadcasts()

      assert :ok = GenServer.call(catalog, :broadcast_next)
      assert [_one_snapshot] = collect_catalog_broadcasts()
    end

    test "live catalog broadcasts carry strictly increasing generations" do
      registry = :"live_providers_#{System.unique_integer([:positive])}"
      task_supervisor = :"live_provider_tasks_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})
      start_supervised!({Task.Supervisor, name: task_supervisor})

      parent = self()

      discover = fn ->
        send(parent, {:probe_started, self()})

        receive do
          :release ->
            {:ok,
             %{
               executable: "/bin/none",
               version: "0",
               models: [],
               credential_count: 0
             }}
        end
      end

      catalog =
        start_supervised!(
          {Catalog,
           name: nil,
           registry: registry,
           task_supervisor: task_supervisor,
           discover: discover,
           discovery?: true}
        )

      assert_receive {:probe_started, first_probe}, 500

      # Subscribing registers this process and pins a baseline version.
      assert %Snapshot{generation: _baseline} = Catalog.subscribe(catalog)

      # The in-flight round publishes its checking state as a new generation.
      checking = next_broadcast()
      assert checking.providers.opencode.status == :checking

      send(first_probe, :release)

      settled = next_broadcast()
      assert settled.providers.opencode.status == :available
      assert settled.generation > checking.generation

      # The subscribed stream continues monotonically from its baseline.
      assert %Snapshot{generation: current} = Catalog.snapshot(catalog)
      assert current >= settled.generation
    end
  end

  defp next_broadcast do
    receive do
      {:provider_catalog_updated, snapshot} -> snapshot
    after
      2_000 -> flunk("expected a catalog broadcast")
    end
  end

  defp mounted_term(assign_overrides) do
    assigns =
      Map.merge(
        %{
          projection: %{sequence: 0, rooms: %{}, room_order: []},
          selected_room_id: nil,
          providers: %{},
          providers_generation: 0,
          notice: nil,
          modal: nil
        },
        assign_overrides
      )

    %{assigns: assigns}
  end

  defp collect_catalog_broadcasts(collected \\ []) do
    receive do
      {:provider_catalog_updated, %Snapshot{} = snapshot} ->
        collect_catalog_broadcasts([snapshot | collected])
    after
      100 -> Enum.reverse(collected)
    end
  end

  defp drain_catalog_broadcasts do
    receive do
      {:provider_catalog_updated, _snapshot} -> drain_catalog_broadcasts()
    after
      0 -> :ok
    end
  end
end
