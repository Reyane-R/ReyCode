defmodule ReyCode.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias ReyCode.Provider.Registry
  alias ReyCode.RuntimeConfig

  @profiles [
    %{
      id: :local_api,
      name: "Local API",
      base_url: "https://local.example.test",
      key_env: "LOCAL_API_KEY"
    }
  ]

  defp config(overrides), do: RuntimeConfig.fresh(overrides)

  test "keeps live provider IDs and descriptors in configured order" do
    cfg = config(openai_compatible_providers: @profiles)

    assert Registry.live_provider_ids(config: cfg, allow_simulator?: false) == [
             :opencode,
             :omp,
             :deepseek,
             :ollama,
             :lmstudio,
             :local_api
           ]

    assert Registry.live_provider_ids(config: cfg, allow_simulator?: true) == [
             :opencode,
             :omp,
             :deepseek,
             :ollama,
             :lmstudio,
             :local_api,
             :simulator
           ]

    assert Enum.map(Registry.descriptors(cfg), &Map.take(&1, [:id, :name, :description])) == [
             %{id: :opencode, name: "OpenCode", description: "CLI runtime"},
             %{id: :omp, name: "OMP", description: "CLI runtime"},
             %{
               id: :deepseek,
               name: "DeepSeek",
               description: "OpenAI-compatible API"
             },
             %{
               id: :ollama,
               name: "Ollama",
               description: "OpenAI-compatible API"
             },
             %{
               id: :lmstudio,
               name: "LM Studio",
               description: "OpenAI-compatible API"
             },
             %{
               id: :local_api,
               name: "Local API",
               description: "OpenAI-compatible API"
             }
           ]

    assert Registry.descriptor(:opencode).module == ReyCode.Provider.OpenCode
    assert Registry.descriptor(:local_api, cfg).module == ReyCode.Provider.OpenAICompatible
    assert Registry.normalize_provider_id("local_api", cfg) == :local_api
    assert Registry.display_name("local_api", cfg) == "Local API"
    assert {:ok, %{id: :local_api}} = Registry.fetch_api_profile("local_api", cfg)

    assert Registry.configurable_provider?("local_api",
             allow_simulator?: false,
             config: cfg
           )
  end

  test "normalizes only known provider strings and preserves historical values" do
    unknown = "provider-that-must-remain-a-string"
    cfg = config(openai_compatible_providers: @profiles)

    assert Registry.normalize_provider_id("opencode") == :opencode
    assert Registry.normalize_provider_id("deepseek") == :deepseek
    assert Registry.normalize_provider_id("ollama") == :ollama
    assert Registry.normalize_provider_id("lmstudio") == :lmstudio
    assert Registry.normalize_provider_id("simulator") == :simulator
    assert Registry.normalize_provider_id("demo") == :demo
    assert Registry.normalize_provider_id("unconfigured") == :unconfigured
    assert Registry.normalize_provider_id(unknown) == unknown
    assert Registry.normalize_provider_id(unknown, cfg) == unknown
  end

  test "owns profile lookup, display names, and configurable-provider decisions" do
    assert {:ok, profile} = Registry.fetch_api_profile("deepseek")
    assert profile.name == "DeepSeek"
    assert Registry.fetch_api_profile("unknown") == {:error, :unknown_provider}

    assert Registry.display_name(:opencode) == "OpenCode"
    assert Registry.display_name("deepseek") == "DeepSeek"
    assert Registry.display_name(:simulator) == "Simulator"
    assert Registry.display_name("unknown") == "unknown"

    assert Registry.configurable_provider?("opencode", allow_simulator?: false)
    assert Registry.configurable_provider?("deepseek", allow_simulator?: false)
    assert Registry.configurable_provider?("ollama", allow_simulator?: false)
    assert Registry.configurable_provider?(:lmstudio, allow_simulator?: false)
    refute Registry.configurable_provider?("simulator", allow_simulator?: false)
    assert Registry.configurable_provider?("simulator", allow_simulator?: true)
    refute Registry.configurable_provider?("unknown", allow_simulator?: true)
    refute Registry.configurable_provider?(:demo, allow_simulator?: true)
  end

  test "the simulator gate reads the injected configuration when not overridden" do
    allowed = config(allow_simulator_provider: true)
    denied = config(allow_simulator_provider: false)

    assert Registry.live_provider_ids(config: allowed) |> List.last() == :simulator
    refute :simulator in Registry.live_provider_ids(config: denied)
  end

  test "display names resolve configured profiles through the injected configuration" do
    cfg = config(openai_compatible_providers: @profiles)

    assert Registry.display_name(:local_api, cfg) == "Local API"
    assert Registry.display_name(:local_api) == "local_api"
  end
end
