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
      {:openai_compatible_providers, [%{}, "x"], ~r/expected a list of provider maps/},
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
