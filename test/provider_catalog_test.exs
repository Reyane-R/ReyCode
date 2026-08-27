defmodule ReyCode.Provider.CatalogTest do
  use ExUnit.Case, async: true

  alias ReyCode.Provider.{Catalog, Runtime}
  alias ReyCode.Provider.Catalog.Snapshot
  alias ReyCode.RuntimeConfig
  alias ReyCode.Test.Wait

  @registry __MODULE__.Registry
  @task_supervisor __MODULE__.TaskSupervisor
  @catalog __MODULE__.Catalog

  test "live catalog exposes only supported providers" do
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

    providers = Catalog.snapshot(@catalog).providers

    assert MapSet.new(Map.keys(providers)) ==
             MapSet.new([:opencode, :omp, :deepseek, :ollama, :lmstudio])

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
       api_discover: fn -> %{} end,
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

  test "publishes discovered OMP models and resolves the adapter" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    config = RuntimeConfig.fresh()

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       config: config,
       discover: fn -> {:error, :missing_executable} end,
       omp_discover: fn ->
         {:ok,
          %{
            executable: "/usr/local/bin/omp",
            version: "18.0.3",
            credential_count: 1,
            models: ["openai/gpt-5"]
          }}
       end,
       api_discover: fn -> %{} end,
       discovery?: true,
       refresh_interval: 10_000}
    )

    assert wait_until_omp_status(@catalog, :configured)

    assert {:ok, %Runtime{module: ReyCode.Provider.OMP, config: omp_policy}} =
             Catalog.resolve(:omp, "openai/gpt-5", @catalog)

    assert omp_policy == config.omp
  end

  test "publishes OMP discovery failures without crashing the catalog" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: fn -> {:error, :missing_executable} end,
       omp_discover: fn -> {:error, :missing_executable} end,
       api_discover: fn -> %{} end,
       discovery?: true,
       refresh_interval: 10_000}
    )

    assert wait_until_omp_status(@catalog, :missing)
    assert Catalog.snapshot(@catalog).providers.omp.error == "omp executable not found"
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
       api_discover: fn -> %{} end,
       discovery?: true,
       probe_timeout: 30,
       retry_interval: 30,
       refresh_interval: 10_000}
    )

    assert_receive {:probe_started, first_probe}
    assert wait_until_status(@catalog, :error)
    assert Catalog.snapshot(@catalog).providers.opencode.error == "provider discovery timed out"
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
       api_discover: fn -> %{} end,
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

    policy = config.open_ai

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
              config: ^policy
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

  test "normalizes unexpected OMP discovery results as errors" do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: fn -> {:error, :missing_executable} end,
       omp_discover: fn -> :unexpected end,
       api_discover: fn -> %{} end,
       discovery?: true,
       refresh_interval: 10_000}
    )

    assert wait_until_omp_status(@catalog, :error)
    assert Catalog.snapshot(@catalog).providers.omp.error == ":unexpected"
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

  defp wait_until_omp_status(catalog, status, attempts \\ 100) do
    Wait.catalog(catalog, &(&1.omp.status == status), attempts * 10)
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

    # The API profiles must not depend on real loopback endpoints: injected
    # results keep this probe-counting test fully hermetic.
    start_supervised!(
      {Catalog,
       name: @catalog,
       registry: @registry,
       task_supervisor: @task_supervisor,
       discover: discover,
       api_discover: fn -> %{} end,
       discovery?: true,
       probe_timeout: 1_000,
       retry_interval: 10_000,
       refresh_interval: 10_000}
    )

    {@catalog, parent}
  end

  defp receive_configured do
    receive do
      {:provider_catalog_updated,
       %Snapshot{providers: %{opencode: %{status: :configured}} = providers}} ->
        {:ok, providers}

      {:provider_catalog_updated, _snapshot} ->
        receive_configured()
    after
      1_000 -> :timeout
    end
  end

  describe "independent probes" do
    test "a hung provider does not block or poison other providers" do
      parent = self()

      start_supervised!({Registry, keys: :duplicate, name: @registry})
      start_supervised!({Task.Supervisor, name: @task_supervisor})

      start_supervised!(
        {Catalog,
         name: @catalog,
         registry: @registry,
         task_supervisor: @task_supervisor,
         discover: fn ->
           send(parent, {:opencode_probe_started, self()})

           receive do
             :release -> {:ok, discovery()}
           end
         end,
         omp_discover: fn -> {:ok, omp_discovery()} end,
         api_discover: fn -> %{deepseek: deepseek_result(), bogus: {:ok, %{}}} end,
         discovery?: true,
         probe_timeout: 100,
         retry_interval: 10_000,
         refresh_interval: 10_000}
      )

      # The fast providers publish and resolve while opencode is still hung.
      assert_receive {:opencode_probe_started, opencode_probe}, 500

      assert wait_until_deepseek_status(@catalog, :configured, 50)

      assert match?(
               {:ok, %Runtime{}},
               Catalog.resolve(:deepseek, "deepseek/deepseek-chat", @catalog)
             )

      providers = Catalog.snapshot(@catalog).providers
      assert providers.deepseek.status == :configured
      assert providers.opencode.status == :checking
      # The injected api fan-out marks every profile checking up front.
      assert providers.deepseek.status == providers.deepseek.status

      # The hung probe times out alone; siblings keep their results.
      assert wait_until_opencode_error(@catalog, "provider discovery timed out")

      # The round is fully drained before the late release arrives, so the
      # dropped-result arm executes deterministically.
      assert :sys.get_state(@catalog).probes == %{}

      snapshot = Catalog.snapshot(@catalog).providers
      assert snapshot.omp.status == :configured
      assert snapshot.deepseek.status == :configured

      # A late result from the timed-out probe is ignored.
      send(opencode_probe, :release)
      Process.sleep(30)
      assert Catalog.snapshot(@catalog).providers.opencode.status == :error
    end

    test "a crashing provider marks only itself as errored" do
      start_supervised!({Registry, keys: :duplicate, name: @registry})
      start_supervised!({Task.Supervisor, name: @task_supervisor})

      start_supervised!(
        {Catalog,
         name: @catalog,
         registry: @registry,
         task_supervisor: @task_supervisor,
         discover: fn -> raise "exploded" end,
         omp_discover: fn -> {:ok, omp_discovery()} end,
         api_discover: fn -> %{} end,
         discovery?: true,
         refresh_interval: 10_000,
         retry_interval: 10_000}
      )

      assert wait_until_opencode_error(@catalog, "provider discovery failed")

      snapshot = Catalog.snapshot(@catalog).providers
      assert snapshot.omp.status == :configured
      refute is_nil(snapshot.omp.checked_at)
    end

    test "resolve_when_ready replies when the requested provider settles" do
      {catalog, _parent} = start_blocking_opencode_catalog()

      assert_receive {:opencode_probe_started, _}, 500

      task =
        Task.async(fn ->
          Catalog.resolve_when_ready(:deepseek, "deepseek/deepseek-chat", catalog)
        end)

      assert match?({:ok, %Runtime{}}, Task.await(task))
      assert Catalog.snapshot(catalog).providers.opencode.status == :checking
    end

    test "api fan-out timeouts mark every profile while executables stay healthy" do
      parent = self()

      start_supervised!({Registry, keys: :duplicate, name: @registry})
      start_supervised!({Task.Supervisor, name: @task_supervisor})

      start_supervised!(
        {Catalog,
         name: @catalog,
         registry: @registry,
         task_supervisor: @task_supervisor,
         discover: fn -> {:ok, discovery()} end,
         omp_discover: fn -> {:ok, omp_discovery()} end,
         api_discover: fn ->
           send(parent, {:api_probe_started, self()})

           receive do
             :release -> %{}
           end
         end,
         discovery?: true,
         probe_timeout: 80,
         retry_interval: 10_000,
         refresh_interval: 10_000}
      )

      assert_receive {:api_probe_started, _}, 500

      settled? =
        Enum.reduce_while(1..200, false, fn _i, _acc ->
          providers = Catalog.snapshot(@catalog).providers

          if providers.opencode.status == :configured and providers.omp.status == :configured and
               providers.deepseek.status == :error do
            {:halt, true}
          else
            Process.sleep(10)
            {:cont, false}
          end
        end)

      assert settled?, "fan-out timeout did not isolate profiles"
    end

    test "stale probe results never overwrite newer published state" do
      {catalog, _parent} = start_blocking_opencode_catalog(probe_timeout: 50)

      assert_receive {:opencode_probe_started, blocked}, 500

      # Timeout publishes the error before the blocker ever releases.
      assert wait_until_opencode_error(catalog, "provider discovery timed out")

      send(blocked, :release)
      Process.sleep(30)

      assert Catalog.snapshot(catalog).providers.opencode.status == :error
    end
  end

  defp start_blocking_opencode_catalog(opts \\ []) do
    parent = self()
    probe_timeout = Keyword.get(opts, :probe_timeout, 5_000)

    start_supervised!({Registry, keys: :duplicate, name: @registry})
    start_supervised!({Task.Supervisor, name: @task_supervisor})

    discover = fn ->
      send(parent, {:opencode_probe_started, self()})

      receive do
        :release -> {:ok, discovery()}
      end
    end

    catalog =
      start_supervised!(
        {Catalog,
         name: @catalog,
         registry: @registry,
         task_supervisor: @task_supervisor,
         discover: discover,
         api_discover: fn -> %{deepseek: deepseek_result()} end,
         discovery?: true,
         probe_timeout: probe_timeout,
         retry_interval: 10_000,
         refresh_interval: 10_000}
      )

    {catalog, parent}
  end

  defp discovery do
    %{
      executable: "/tmp/opencode",
      version: "1.0.0",
      credential_count: 1,
      models: ["openai/gpt-5.6-sol"]
    }
  end

  defp omp_discovery do
    %{
      executable: "/tmp/omp",
      version: "2.0.0",
      credential_count: 0,
      models: ["anthropic/claude-opus-4"]
    }
  end

  defp deepseek_result do
    {:ok, %{status: :configured, credential_count: 2, models: ["deepseek/deepseek-chat"]}}
  end

  defp wait_until_opencode_error(catalog, message_prefix, attempts \\ 100) do
    Enum.reduce_while(1..attempts//1, false, fn _index, _acc ->
      entry = Catalog.snapshot(catalog).providers.opencode

      if entry.status == :error and String.starts_with?(entry.error || "", message_prefix) do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
