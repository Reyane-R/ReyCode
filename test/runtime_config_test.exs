defmodule ReyCode.RuntimeConfigTest do
  @moduledoc "Coverage for the declarative runtime configuration schema."

  use ExUnit.Case, async: false

  alias ReyCode.RuntimeConfig

  setup do
    previously_declared =
      Enum.map(RuntimeConfig.declared_defaults(), fn {key, _default} ->
        {key, Application.get_env(:rey_code, key)}
      end)

    on_exit(fn ->
      Enum.each(previously_declared, fn
        {key, nil} -> Application.delete_env(:rey_code, key)
        {key, value} -> Application.put_env(:rey_code, key, value)
      end)
    end)

    :ok
  end

  test "loads every declared setting with its default when unconfigured" do
    Enum.each(RuntimeConfig.declared_defaults(), fn {key, _} ->
      Application.delete_env(:rey_code, key)
    end)

    config = RuntimeConfig.load!()

    for {key, default} <- RuntimeConfig.declared_defaults() do
      assert Map.fetch!(config, key) == default,
             "expected #{inspect(key)} to default to #{inspect(default)}"
    end

    # Settings the issue called out as previously unvalidated drift risks.
    assert %RuntimeConfig{} = config
    refute Map.has_key?(config, :event_path)
    refute Map.has_key?(config, :data_dir)
    refute Map.has_key?(config, :start_tui)
    assert config.opencode_max_prompt_bytes > 0
    assert config.opencode_max_output_bytes > 0
    assert config.opencode_max_diagnostic_bytes > 0
  end

  test "reads configured values instead of defaults" do
    Application.put_env(:rey_code, :provider_timeout_ms, 1_234)
    Application.put_env(:rey_code, :global_concurrency, 7)
    Application.put_env(:rey_code, :workspace_roots, ["/tmp/a", "/tmp/b"])

    config = RuntimeConfig.load!()

    assert config.provider_timeout_ms == 1_234
    assert config.global_concurrency == 7
    assert config.workspace_roots == ["/tmp/a", "/tmp/b"]
  end

  test "accepts :infinity only for concurrency and queue limits" do
    Application.put_env(:rey_code, :global_queue_limit, :infinity)
    assert %RuntimeConfig{} = RuntimeConfig.load!()

    Application.put_env(:rey_code, :provider_timeout_ms, :infinity)

    assert_raise ArgumentError, ~r/invalid provider_timeout_ms/, fn ->
      RuntimeConfig.load!()
    end
  end

  test "rejects out-of-bounds integers with the setting name and bound" do
    Application.put_env(:rey_code, :agent_delay_ms, -1)

    assert_raise ArgumentError, ~r/invalid agent_delay_ms.*>= 0/s, fn ->
      RuntimeConfig.load!()
    end
  end

  test "rejects wrong types with a shape hint" do
    cases = [
      {:provider_discovery, "yes", ~r/expected true or false/},
      {:default_provider, "simulator", ~r/expected an atom/},
      {:opencode_max_output_bytes, "lots", ~r/invalid opencode_max_output_bytes/},
      {:opencode_env_allowlist, ["A", 2], ~r/expected a list of strings/},
      {:openai_compatible_providers, [%{}, "x"], ~r/providers\[0\]\.id.*missing/},
      {:squad_simulator, %{seed: 0}, ~r/expected a keyword list/},
      {:workspace_roots, "/only", ~r/expected a list/},
      {:log_dir, 42, ~r/expected a string path/}
    ]

    Enum.each(cases, fn {key, value, expectation} ->
      previous = Application.get_env(:rey_code, key)

      Application.put_env(:rey_code, key, value)

      assert_raise ArgumentError, expectation, fn ->
        RuntimeConfig.load!()
      end

      restore(key, previous)
    end)
  end

  test "validates nested provider profiles at the configuration boundary" do
    valid = %{
      id: :local,
      name: "Local",
      base_url: "https://local.example.test",
      key_env: "LOCAL_API_KEY"
    }

    assert %RuntimeConfig{} = RuntimeConfig.fresh(openai_compatible_providers: [valid])

    for {profile, expectation} <- [
          {%{}, ~r/openai_compatible_providers\[0\]\.id.*missing/},
          {%{valid | base_url: "file:///tmp/socket"}, ~r/base_url.*HTTP\(S\)/},
          {%{valid | base_url: "ftp://local.example.test"}, ~r/base_url.*HTTP\(S\)/},
          {%{valid | base_url: "https://"}, ~r/base_url.*HTTP\(S\)/},
          {%{valid | base_url: "https://local example.test"}, ~r/base_url.*HTTP\(S\)/},
          {Map.put(valid, :request_timeout_ms, 0), ~r/request_timeout_ms.*>= 1/},
          {%{valid | id: :opencode}, ~r/reserved provider id/}
        ] do
      assert_raise ArgumentError, expectation, fn ->
        RuntimeConfig.fresh(openai_compatible_providers: [profile])
      end
    end
  end

  test "validates simulator options and rejects unknown explicit overrides" do
    assert %RuntimeConfig{} =
             RuntimeConfig.fresh(squad_simulator: [delay_ms: 0, emit_process: :task])

    assert_raise ArgumentError, ~r/squad_simulator\.failure_rate/, fn ->
      RuntimeConfig.fresh(squad_simulator: [failure_rate: 1.5])
    end

    assert_raise ArgumentError, ~r/unknown options.*mystery/, fn ->
      RuntimeConfig.fresh(squad_simulator: [mystery: true])
    end

    assert_raise ArgumentError, ~r/unknown runtime configuration overrides.*typo/, fn ->
      RuntimeConfig.fresh(typo: true)
    end
  end

  test "policy uses its fallback only when no injected configuration exists" do
    assert RuntimeConfig.policy(nil, :provider_timeout_ms, 123) == 123

    assert RuntimeConfig.policy(
             RuntimeConfig.fresh(provider_timeout_ms: 456),
             :provider_timeout_ms,
             123
           ) ==
             456
  end

  test "rejects an unloaded transport module but accepts a loaded one or nil" do
    Application.put_env(:rey_code, :openai_compatible_transport, NoSuch.Transport)
    full_key = ~r/invalid openai_compatible_transport/

    assert_raise ArgumentError, full_key, fn -> RuntimeConfig.load!() end

    Application.put_env(:rey_code, :openai_compatible_transport, ReyCode.RuntimeConfig)
    assert %RuntimeConfig{} = RuntimeConfig.load!()

    Application.delete_env(:rey_code, :openai_compatible_transport)
    assert %RuntimeConfig{} = RuntimeConfig.load!()
  end

  test "validate!/0 returns :ok for the current environment" do
    assert :ok = RuntimeConfig.validate!()
  end

  defp restore(key, nil), do: Application.delete_env(:rey_code, key)
  defp restore(key, value), do: Application.put_env(:rey_code, key, value)
end
