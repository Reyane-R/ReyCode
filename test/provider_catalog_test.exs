defmodule ReyCode.Provider.CatalogTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.{Catalog, Runtime}
  alias ReyCode.RuntimeConfig
  alias ReyCode.Test.Wait

  @registry __MODULE__.Registry
  @task_supervisor __MODULE__.TaskSupervisor
  @catalog __MODULE__.Catalog

  test "live catalog exposes only OpenCode" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discovery?: false,
       allow_simulator?: false}
    )

    providers = Catalog.snapshot(@catalog)
    assert Map.keys(providers) == [:opencode, :deepseek]
    refute Map.has_key?(providers, :demo)
    refute Map.has_key?(providers, :simulator)
  end

  test "publishes discovered OpenCode models and resolves the adapter" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    identity = %{
      path: "/usr/local/bin/opencode",
      device: {1, 2},
      inode: 3,
      sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    }

    discover = fn ->
      {:ok,
       %{
         executable: "/usr/local/bin/opencode",
         executable_identity: identity,
         version: "1.18.11",
         credential_count: 2,
         models: ["openai/gpt-5.6-sol"]
       }}
    end

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: discover,
       discovery?: true}
    )

    assert wait_until_configured(@catalog)
    Catalog.subscribe(@catalog)
    Catalog.refresh(@catalog)
    assert {:ok, providers} = receive_configured()
    assert providers.opencode.status == :configured
    assert providers.opencode.credential_count == 2

    assert {:ok,
            %Runtime{
              module: ReyCode.Provider.OpenCode,
              executable: "/usr/local/bin/opencode",
              executable_identity: ^identity,
              version: "1.18.11",
              models: ["openai/gpt-5.6-sol"],
              status: :configured
            }} = Catalog.resolve(:opencode, "openai/gpt-5.6-sol", @catalog)

    assert {:error, :model_unavailable} = Catalog.resolve(:opencode, "openai/missing", @catalog)
  end

  test "runs only one probe across repeated manual refreshes" do
    {catalog, parent} = start_controlled_catalog()

    assert_receive {:probe_started, first_probe}

    Enum.each(1..5, fn _ -> Catalog.refresh(catalog) end)
    refute_receive {:probe_started, _}, 50

    send(first_probe, :finish_probe)
    assert wait_until_configured(catalog)

    Enum.each(1..5, fn _ -> Catalog.refresh(catalog) end)
    assert_receive {:probe_started, second_probe}
    refute second_probe == first_probe
    refute_receive {:probe_started, _}, 50

    send(second_probe, :finish_probe)
    assert wait_until_configured(catalog)
    assert parent == self()
  end

  test "times out a stuck probe and schedules one retry" do
    parent = self()

    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    discover = fn ->
      send(parent, {:probe_started, self()})
      receive do: (:never -> :ok)
    end

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: discover,
       discovery?: true,
       probe_timeout: 30,
       retry_interval: 30,
       refresh_interval: 10_000}
    )

    assert_receive {:probe_started, first_probe}
    assert wait_until_status(@catalog, :error)
    assert Catalog.snapshot(@catalog).opencode.error == "provider discovery timed out"
    assert_receive {:probe_started, second_probe}, 250
    refute first_probe == second_probe
    GenServer.stop(@catalog)
  end

  test "waits for a slow successful probe before resolving an invocation" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    discover = fn ->
      Process.sleep(100)

      {:ok,
       %{
         executable: "/tmp/opencode",
         version: "1.0.0",
         credential_count: 1,
         models: ["openai/gpt-5.6-sol"]
       }}
    end

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: discover,
       discovery?: true,
       probe_timeout: 500,
       refresh_interval: 10_000}
    )

    assert {:ok, %Runtime{executable: "/tmp/opencode"}} =
             Catalog.resolve_when_ready(:opencode, "openai/gpt-5.6-sol", @catalog)
  end

  test "publishes discovered OpenAI-compatible providers and resolves them" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    discover = fn -> {:ok, %{executable: nil, version: nil, credential_count: 0, models: []}} end

    api_discover = fn ->
      %{
        deepseek:
          {:ok,
           %{
             status: :configured,
             models: ["deepseek-chat", "deepseek-reasoner"],
             credential_count: 1
           }}
      }
    end

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: discover,
       api_discover: api_discover,
       discovery?: true}
    )

    assert wait_until_deepseek_configured(@catalog)

    assert {:ok,
            %Runtime{
              module: ReyCode.Provider.OpenAICompatible,
              provider_id: :deepseek,
              models: ["deepseek-chat", "deepseek-reasoner"],
              status: :configured
            }} = Catalog.resolve(:deepseek, "deepseek-chat", @catalog)

    assert {:error, :model_unavailable} = Catalog.resolve(:deepseek, "deepseek-missing", @catalog)
  end

  test "preserves configured API profiles through discovery and resolution" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    config =
      RuntimeConfig.fresh(
        openai_compatible_providers: [
          %{
            id: :local_api,
            name: "Local API",
            base_url: "https://local.example.test",
            key_env: "LOCAL_API_KEY"
          }
        ]
      )

    api_discover = fn ->
      %{
        local_api:
          {:ok, %{status: :configured, models: ["local-model"], credential_count: 1, error: nil}}
      }
    end

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       config: config,
       discover: fn -> {:error, :missing_executable} end,
       api_discover: api_discover,
       discovery?: true}
    )

    assert {:ok,
            %Runtime{
              provider_id: :local_api,
              module: ReyCode.Provider.OpenAICompatible,
              models: ["local-model"],
              config: ^config
            }} = Catalog.resolve_when_ready(:local_api, "local-model", @catalog)
  end

  test "an API provider without a key resolves to available and refuses to run" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    System.delete_env("DEEPSEEK_API_KEY")

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: fn -> {:error, :missing_executable} end,
       discovery?: true}
    )

    assert wait_until_deepseek_status(@catalog, :available)
    assert {:error, :available} = Catalog.resolve(:deepseek, "deepseek-chat", @catalog)
  end

  defp wait_until_deepseek_configured(catalog),
    do: wait_until_deepseek_status(catalog, :configured)

  defp wait_until_deepseek_status(catalog, status, attempts \\ 100) do
    Wait.catalog(
      catalog,
      fn providers -> match?(%{status: ^status}, providers[:deepseek]) end,
      attempts * 10
    )
  end

  defp wait_until_configured(catalog, attempts \\ 100) do
    Wait.catalog(catalog, &(&1.opencode.status == :configured), attempts * 10)
  end

  defp wait_until_status(catalog, status, attempts \\ 100) do
    Wait.catalog(catalog, &(&1.opencode.status == status), attempts * 5)
  end

  defp start_controlled_catalog do
    parent = self()

    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    discover = fn ->
      send(parent, {:probe_started, self()})

      receive do
        :finish_probe ->
          {:ok,
           %{
             executable: "/tmp/opencode",
             version: "1.0.0",
             credential_count: 1,
             models: ["openai/gpt-5.6-sol"]
           }}
      end
    end

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: discover,
       discovery?: true,
       probe_timeout: 1_000,
       retry_interval: 10_000,
       refresh_interval: 10_000}
    )

    {@catalog, parent}
  end

  defp receive_configured do
    receive do
      {:provider_catalog_updated, %{opencode: %{status: :configured}} = providers} ->
        {:ok, providers}

      {:provider_catalog_updated, _providers} ->
        receive_configured()
    after
      1_000 -> :timeout
    end
  end
end
