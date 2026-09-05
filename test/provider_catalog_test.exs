defmodule ReyCode.Provider.CatalogTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.{Catalog, OpenAICompatible, Runtime}
  alias ReyCode.RuntimeConfig
  alias ReyCode.Test.Wait

  @registry __MODULE__.Registry
  @task_supervisor __MODULE__.Tasks
  @catalog __MODULE__.Catalog

  setup do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})
    :ok
  end

  test "discovers model APIs and freezes the selected profile policy" do
    config = RuntimeConfig.fresh(openai_compatible_chunk_bytes: 64)
    catalog = start_catalog(config: config)
    assert status?(catalog, :deepseek, :configured)

    assert {:ok, %Runtime{module: OpenAICompatible, provider_id: :deepseek} = runtime} =
             Catalog.resolve("deepseek", "deepseek-chat", catalog)

    assert runtime.config == config.open_ai
    assert runtime.workspace_policy == config.workspace
    refute Map.has_key?(runtime, :executable)
    assert {:error, :model_required} = Catalog.resolve(:deepseek, nil, catalog)
    assert {:error, :model_unavailable} = Catalog.resolve(:deepseek, "missing-model", catalog)
  end

  test "retired CLI providers are absent and cannot resolve" do
    catalog = start_catalog()

    for provider <- [:opencode, :omp, :open_code, "opencode", "omp", "open_code"] do
      assert {:error, :unknown_provider} = Catalog.resolve(provider, "any-model", catalog)
      assert {:error, :unknown_provider} = Catalog.resolve_when_ready(provider, nil, catalog)
    end

    assert Enum.sort(Map.keys(Catalog.snapshot(catalog).providers)) ==
             [:deepseek, :lmstudio, :ollama]
  end

  test "disabled discovery performs no probes" do
    parent = self()
    catalog = start_catalog(discovery?: false, discover: fn _ -> send(parent, :probed) end)
    assert Catalog.snapshot(catalog).providers.deepseek.status == :unchecked
    assert {:error, :unchecked} = Catalog.resolve(:deepseek, "deepseek-chat", catalog)
    Catalog.refresh(catalog)
    assert Catalog.snapshot(catalog).providers.deepseek.status == :unchecked
    refute_received :probed
  end

  test "simulator is available only when explicitly enabled" do
    catalog = start_catalog(config: RuntimeConfig.fresh(allow_simulator_provider: true))

    assert {:ok, %Runtime{module: ReyCode.Provider.Simulator}} =
             Catalog.resolve(:simulator, nil, catalog)
  end

  test "unconfigured API credentials return an actionable unavailable state" do
    catalog = start_catalog(discover: fn _ -> {:ok, %{status: :available, models: []}} end)
    assert status?(catalog, :deepseek, :available)
    assert {:error, :available} = Catalog.resolve(:deepseek, "deepseek-chat", catalog)
  end

  test "tagged and malformed discovery failures become visible errors" do
    catalog =
      start_catalog(
        discover: fn
          %{id: :deepseek} -> {:error, :offline}
          %{id: :ollama} -> :unexpected
          profile -> discovery(profile)
        end
      )

    assert status?(catalog, :deepseek, :error)
    assert status?(catalog, :ollama, :error)
    assert status?(catalog, :lmstudio, :configured)
    providers = Catalog.snapshot(catalog).providers
    assert providers.deepseek.error == "offline"
    assert providers.ollama.error == "unexpected"
  end

  test "a hung API does not block another API or its readiness waiters" do
    parent = self()

    catalog =
      start_catalog(
        probe_timeout: 200,
        discover: fn
          %{id: :deepseek} ->
            send(parent, {:blocked_probe, self()})

            receive do
              :release -> discovery(%{id: :deepseek})
            after
              2_000 -> {:error, :probe_deadline}
            end

          profile ->
            discovery(profile)
        end
      )

    assert_receive {:blocked_probe, pid}, 1_000
    ref = Process.monitor(pid)

    assert {:ok, %Runtime{provider_id: :ollama}} =
             Catalog.resolve_when_ready(:ollama, "ollama-chat", catalog)

    assert status?(catalog, :deepseek, :error)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert Catalog.snapshot(catalog).providers.deepseek.error == "provider discovery timed out"
    assert Catalog.snapshot(catalog).providers.ollama.status == :configured
  end

  test "a crashing probe affects only its own API" do
    catalog =
      start_catalog(
        discover: fn
          %{id: :deepseek} -> raise "probe crashed"
          profile -> discovery(profile)
        end
      )

    assert status?(catalog, :deepseek, :error)
    assert status?(catalog, :ollama, :configured)
    assert Catalog.snapshot(catalog).providers.deepseek.error =~ "provider discovery failed"
  end

  test "readiness waiters receive the selected API result" do
    parent = self()

    catalog =
      start_catalog(
        discover: fn
          %{id: :deepseek} = profile ->
            send(parent, {:probe, self()})

            receive do
              :release -> discovery(profile)
            after
              2_000 -> {:error, :probe_deadline}
            end

          profile ->
            discovery(profile)
        end
      )

    assert_receive {:probe, pid}, 1_000
    waiter = Task.async(fn -> Catalog.resolve_when_ready(:deepseek, "deepseek-chat", catalog) end)
    send(pid, :release)
    assert {:ok, %Runtime{provider_id: :deepseek}} = Task.await(waiter)
  end

  test "subscriptions are idempotent and refreshes never overlap probes" do
    parent = self()

    catalog =
      start_catalog(
        discover: fn profile ->
          send(parent, {:probe, profile.id, self()})

          receive do
            :release -> discovery(profile)
          after
            2_000 -> {:error, :probe_deadline}
          end
        end
      )

    baseline = Catalog.subscribe(catalog)
    Catalog.subscribe(catalog)
    assert length(Registry.lookup(@registry, :providers)) == 1

    probes =
      for _ <- 1..3 do
        assert_receive {:probe, _id, pid}, 1_000
        pid
      end

    Catalog.refresh(catalog)
    assert Catalog.snapshot(catalog).generation == baseline.generation
    refute_received {:probe, _, _}
    Enum.each(probes, &send(&1, :release))
    assert status?(catalog, :deepseek, :configured)
    assert Catalog.snapshot(catalog).generation > baseline.generation
  end

  test "late or unrelated messages cannot overwrite published discovery" do
    catalog = start_catalog()
    assert status?(catalog, :deepseek, :configured)
    assert status?(catalog, :ollama, :configured)
    assert status?(catalog, :lmstudio, :configured)
    baseline = Catalog.snapshot(catalog)
    send(catalog, {make_ref(), {:ok, %{status: :error}}})
    send(catalog, {:probe_timeout, make_ref()})
    send(catalog, {:scheduled_refresh, make_ref()})
    assert Catalog.snapshot(catalog) == baseline
  end

  defp start_catalog(opts \\ []) do
    defaults = [
      name: @catalog,
      registry: @registry,
      task_supervisor: @task_supervisor,
      discover: &discovery/1,
      discovery?: true,
      probe_timeout: 1_000,
      retry_interval: 60_000,
      refresh_interval: 60_000
    ]

    start_supervised!({Catalog, Keyword.merge(defaults, opts)})
  end

  defp discovery(profile),
    do: {:ok, %{status: :configured, credential_count: 0, models: ["#{profile.id}-chat"]}}

  defp status?(catalog, provider, status),
    do: Wait.catalog(catalog, &(Map.fetch!(&1, provider).status == status), 2_000)
end
