defmodule ReyCode.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias ReyCode.Provider.Registry

  setup do
    previous_profiles = Application.fetch_env(:rey_code, :openai_compatible_providers)

    on_exit(fn ->
      case previous_profiles do
        {:ok, profiles} ->
          Application.put_env(:rey_code, :openai_compatible_providers, profiles)

        :error ->
          Application.delete_env(:rey_code, :openai_compatible_providers)
      end
    end)

    :ok
  end

  test "keeps live provider IDs and descriptors in configured order" do
    Application.put_env(:rey_code, :openai_compatible_providers, [
      %{
        id: :local_api,
        name: "Local API",
        base_url: "https://local.example.test",
        key_env: "LOCAL_API_KEY"
      }
    ])

    assert Registry.live_provider_ids(allow_simulator?: false) == [
             :opencode,
             :deepseek,
             :local_api
           ]

    assert Registry.live_provider_ids(allow_simulator?: true) == [
             :opencode,
             :deepseek,
             :local_api,
             :simulator
           ]

    assert Enum.map(Registry.descriptors(), &Map.take(&1, [:id, :name, :description])) == [
             %{id: :opencode, name: "OpenCode", description: "CLI runtime"},
             %{
               id: :deepseek,
               name: "DeepSeek",
               description: "OpenAI-compatible API"
             },
             %{
               id: :local_api,
               name: "Local API",
               description: "OpenAI-compatible API"
             }
           ]

    assert Registry.descriptor(:opencode).module == ReyCode.Provider.OpenCode
    assert Registry.descriptor(:local_api).module == ReyCode.Provider.OpenAICompatible
    assert Registry.normalize_provider_id("local_api") == :local_api
    assert Registry.display_name("local_api") == "Local API"
    assert {:ok, %{id: :local_api}} = Registry.fetch_api_profile("local_api")
    assert Registry.configurable_provider?("local_api", allow_simulator?: false)
  end

  test "normalizes only known provider strings and preserves historical values" do
    unknown = "provider-that-must-remain-a-string"

    assert Registry.normalize_provider_id("opencode") == :opencode
    assert Registry.normalize_provider_id("deepseek") == :deepseek
    assert Registry.normalize_provider_id("simulator") == :simulator
    assert Registry.normalize_provider_id("demo") == :demo
    assert Registry.normalize_provider_id("unconfigured") == :unconfigured
    assert Registry.normalize_provider_id(unknown) == unknown
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
    refute Registry.configurable_provider?("simulator", allow_simulator?: false)
    assert Registry.configurable_provider?("simulator", allow_simulator?: true)
    refute Registry.configurable_provider?("unknown", allow_simulator?: true)
    refute Registry.configurable_provider?(:demo, allow_simulator?: true)
  end
end
