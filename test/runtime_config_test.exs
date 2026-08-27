defmodule ReyCode.RuntimeConfigTest do
  @moduledoc "Coverage for the declarative runtime configuration schema."

  use ExUnit.Case, async: true

  alias ReyCode.RuntimeConfig

  # Configuration tests inject an explicit settings source; they never mutate
  # the global application environment, so no serialization is required.
  defp load_with(settings, environment \\ %{}) do
    RuntimeConfig.load(
      fn key, default -> Map.get(settings, key, default) end,
      &Map.get(environment, &1)
    )
  end

  test "loads every declared setting with its default when unconfigured" do
    config = load_with(%{})

    assert flatten(config) == RuntimeConfig.declared_defaults()

    # Settings the issue called out as previously unvalidated drift risks.
    assert %RuntimeConfig{} = config
    refute Map.has_key?(config, :event_path)
    refute Map.has_key?(config, :data_dir)
    refute Map.has_key?(config, :start_tui)
    assert config.open_code.max_prompt_bytes > 0
    assert config.open_code.max_output_bytes > 0
    assert config.open_code.max_diagnostic_bytes > 0
  end

  test "reads configured values instead of defaults" do
    config =
      load_with(%{
        provider_timeout_ms: 1_234,
        global_concurrency: 7,
        workspace_roots: ["/tmp/a", "/tmp/b"]
      })

    assert config.open_code.provider_timeout_ms == 1_234
    assert config.orchestration.global_concurrency == 7
    assert config.workspace.roots == ["/tmp/a", "/tmp/b"]
  end

  test "assembles reduced-motion presentation policy" do
    assert RuntimeConfig.fresh(tui_reduced_motion: true).tui.reduced_motion?
    refute RuntimeConfig.fresh().tui.reduced_motion?
  end

  test "accepts :infinity only for concurrency and queue limits" do
    assert %RuntimeConfig{} = load_with(%{global_queue_limit: :infinity})

    assert_raise ArgumentError, ~r/invalid provider_timeout_ms/, fn ->
      load_with(%{provider_timeout_ms: :infinity})
    end
  end

  test "rejects out-of-bounds integers with the setting name and bound" do
    assert_raise ArgumentError, ~r/invalid agent_delay_ms.*>= 0/s, fn ->
      load_with(%{agent_delay_ms: -1})
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
      assert_raise ArgumentError, expectation, fn ->
        load_with(%{key => value})
      end
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

  test "validates capability override shapes at the configuration boundary" do
    for {capability, expectation} <- [
          {%{deepseek: %{supports_tools: "yes"}},
           ~r/expected supports_tools or supports_stream_options booleans/},
          {%{deepseek: [:invalid]}, ~r/expected %\{provider_atom => capability flags\}/},
          {"not-a-map", ~r/expected %\{provider_atom => capability flags\}/}
        ] do
      assert_raise ArgumentError, expectation, fn ->
        RuntimeConfig.fresh(openai_compatible_capability_overrides: capability)
      end
    end

    assert %RuntimeConfig{} =
             RuntimeConfig.fresh(squad_simulator: [failure_plan: %{retryable: :retryable}])

    assert_raise ArgumentError, ~r/failure_plan.*expected a failure map/s, fn ->
      RuntimeConfig.fresh(squad_simulator: [failure_plan: %{retryable: :bogus}])
    end

    assert_raise ArgumentError, ~r/failure_plan/, fn ->
      RuntimeConfig.fresh(squad_simulator: [failure_plan: :bogus])
    end
  end

  test "environment capability flags override one field without erasing configured siblings" do
    config =
      load_with(
        %{openai_compatible_capability_overrides: %{deepseek: %{supports_tools: false}}},
        %{"REYCODE_DEEPSEEK_SUPPORTS_STREAM_OPTIONS" => "false"}
      )

    assert config.open_ai.capability_overrides.deepseek == %{
             supports_tools: false,
             supports_stream_options: false
           }
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

  test "assembles focused policies without flat runtime fields" do
    config = RuntimeConfig.fresh(provider_timeout_ms: 456)

    assert config.open_code.provider_timeout_ms == 456
    refute Map.has_key?(config, :provider_timeout_ms)
    refute Map.has_key?(config, :tool_bash_timeout_ms)
    refute Map.has_key?(config, :workspace_roots)
  end

  test "rejects an unloaded transport module but accepts a loaded one or nil" do
    full_key = ~r/invalid openai_compatible_transport/

    assert_raise ArgumentError, full_key, fn ->
      load_with(%{openai_compatible_transport: NoSuch.Transport})
    end

    assert %RuntimeConfig{} = load_with(%{openai_compatible_transport: ReyCode.RuntimeConfig})
    assert %RuntimeConfig{} = load_with(%{})
  end

  test "load!/1 reads the live application environment without mutating it" do
    assert %RuntimeConfig{} = RuntimeConfig.load!()
  end

  test "validate!/0 returns :ok for the current environment" do
    assert :ok = RuntimeConfig.validate!()
  end

  defp flatten(config) do
    %{
      context_budget_tokens: config.orchestration.context_budget_tokens,
      global_concurrency: config.orchestration.global_concurrency,
      workspace_concurrency: config.orchestration.workspace_concurrency,
      global_queue_limit: config.orchestration.global_queue_limit,
      workspace_queue_limit: config.orchestration.workspace_queue_limit,
      agent_delay_ms: config.orchestration.agent_delay_ms,
      delegation_max_children_per_invocation: config.orchestration.delegation_max_children,
      delegation_brief_max_bytes: config.orchestration.delegation_brief_max_bytes,
      allow_simulator_provider: config.providers.allow_simulator?,
      steering_max_pending: config.orchestration.steering_max_pending,
      steering_max_bytes: config.orchestration.steering_max_bytes,
      default_provider: config.providers.default_provider,
      provider_discovery: config.providers.discovery?,
      provider_timeout_ms: config.open_code.provider_timeout_ms,
      provider_discovery_command_timeout_ms: config.providers.discovery_command_timeout_ms,
      provider_discovery_output_bytes: config.providers.discovery_output_bytes,
      opencode_path: config.open_code.path,
      opencode_max_prompt_bytes: config.open_code.max_prompt_bytes,
      opencode_max_output_bytes: config.open_code.max_output_bytes,
      opencode_max_diagnostic_bytes: config.open_code.max_diagnostic_bytes,
      opencode_text_chunk_bytes: config.open_code.text_chunk_bytes,
      opencode_text_chunk_latency_ms: config.open_code.text_chunk_latency_ms,
      opencode_cpu_seconds: config.open_code.cpu_seconds,
      opencode_open_files: config.open_code.open_files,
      opencode_env_allowlist: config.open_code.env_allowlist,
      omp_path: config.omp.path,
      omp_max_prompt_bytes: config.omp.max_prompt_bytes,
      omp_max_output_bytes: config.omp.max_output_bytes,
      omp_max_diagnostic_bytes: config.omp.max_diagnostic_bytes,
      omp_text_chunk_bytes: config.omp.text_chunk_bytes,
      omp_text_chunk_latency_ms: config.omp.text_chunk_latency_ms,
      omp_cpu_seconds: config.omp.cpu_seconds,
      omp_open_files: config.omp.open_files,
      omp_env_allowlist: config.omp.env_allowlist,
      omp_discovery_output_bytes: config.omp.discovery_output_bytes,
      openai_compatible_chunk_bytes: config.open_ai.chunk_bytes,
      openai_compatible_chunk_latency_ms: config.open_ai.chunk_latency_ms,
      openai_compatible_base_url_overrides: config.open_ai.base_url_overrides,
      openai_compatible_capability_overrides: config.open_ai.capability_overrides,
      openai_compatible_providers: config.open_ai.profiles,
      openai_compatible_transport: config.open_ai.transport,
      squad_release_gate_human: config.squad.release_gate_human?,
      squad_rework_budget: config.squad.rework_budget,
      squad_simulator: config.squad.simulator,
      projection_checkpoint_interval: config.persistence.checkpoint_interval,
      max_replay_events: config.persistence.max_replay_events,
      max_checkpoint_bytes: config.persistence.max_checkpoint_bytes,
      tool_bash_timeout_ms: config.tools.bash.timeout_ms,
      tool_bash_max_output_bytes: config.tools.bash.max_output_bytes,
      tool_bash_max_error_bytes: config.tools.bash.max_error_bytes,
      tool_bash_env_allowlist: config.tools.bash.env_allowlist,
      tool_bash_cpu_seconds: config.tools.bash.cpu_seconds,
      tool_bash_open_files: config.tools.bash.open_files,
      tool_read_max_bytes: config.tools.read.max_bytes,
      tool_read_max_lines: config.tools.read.max_lines,
      tool_edit_max_bytes: config.tools.edit.max_bytes,
      tool_edit_max_patches: config.tools.edit.max_patches,
      tool_write_max_bytes: config.tools.write.max_bytes,
      tool_glob_max_results: config.tools.glob.max_results,
      tool_list_max_entries: config.tools.list.max_entries,
      tool_list_timeout_ms: config.tools.list.timeout_ms,
      tool_grep_max_matches: config.tools.grep.max_matches,
      tool_grep_max_file_bytes: config.tools.grep.max_file_bytes,
      tool_grep_max_files: config.tools.grep.max_files,
      tool_grep_timeout_ms: config.tools.grep.timeout_ms,
      tool_lsp_command: config.tools.lsp.command,
      tool_lsp_timeout_ms: config.tools.lsp.timeout_ms,
      tool_lsp_max_output_bytes: config.tools.lsp.max_output_bytes,
      tool_lsp_max_file_bytes: config.tools.lsp.max_file_bytes,
      tool_lsp_max_edits: config.tools.lsp.max_edits,
      tool_lsp_env_allowlist: config.tools.lsp.env_allowlist,
      tool_lsp_cpu_seconds: config.tools.lsp.cpu_seconds,
      tool_lsp_open_files: config.tools.lsp.open_files,
      tool_process_max_processes: config.tools.process.max_processes,
      tool_process_max_output_bytes: config.tools.process.max_output_bytes,
      tool_process_stop_timeout_ms: config.tools.process.stop_timeout_ms,
      tool_process_env_allowlist: config.tools.process.env_allowlist,
      tool_process_cpu_seconds: config.tools.process.cpu_seconds,
      tool_process_open_files: config.tools.process.open_files,
      tool_debugger_command: config.tools.debugger.command,
      tool_debugger_timeout_ms: config.tools.debugger.timeout_ms,
      tool_debugger_max_output_bytes: config.tools.debugger.max_output_bytes,
      tool_debugger_env_allowlist: config.tools.debugger.env_allowlist,
      tool_debugger_cpu_seconds: config.tools.debugger.cpu_seconds,
      tool_debugger_open_files: config.tools.debugger.open_files,
      tool_evaluation_python_command: config.tools.evaluation.python_command,
      tool_evaluation_javascript_command: config.tools.evaluation.javascript_command,
      tool_evaluation_timeout_ms: config.tools.evaluation.timeout_ms,
      tool_evaluation_max_code_bytes: config.tools.evaluation.max_code_bytes,
      tool_evaluation_max_output_bytes: config.tools.evaluation.max_output_bytes,
      tool_evaluation_max_kernels: config.tools.evaluation.max_kernels,
      tool_evaluation_env_allowlist: config.tools.evaluation.env_allowlist,
      tool_evaluation_cpu_seconds: config.tools.evaluation.cpu_seconds,
      tool_evaluation_open_files: config.tools.evaluation.open_files,
      web_search_endpoint: config.tools.research.search_endpoint,
      web_search_key_env: config.tools.research.search_key_env,
      web_search_timeout_ms: config.tools.research.search_timeout_ms,
      web_search_max_results: config.tools.research.max_results,
      web_search_max_bytes: config.tools.research.max_bytes,
      document_read_timeout_ms: config.tools.research.document_timeout_ms,
      tui_reduced_motion: config.tui.reduced_motion?,
      workspace_roots: config.workspace.roots,
      file_logging: config.logging.enabled?,
      log_dir: config.logging.log_dir
    }
  end
end
