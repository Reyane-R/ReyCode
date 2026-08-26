defmodule ReyCode.RuntimeConfig.Schema do
  @moduledoc "Declares runtime settings and validates configured or explicit values."

  # setting declarations
  # {key, default-lambda, kind} — validated by validate_kind!/3.
  alias ReyCode.Orchestration.Squad

  defp settings do
    [
      # Orchestration limits
      {:context_budget_tokens, fn -> 200_000 end, {:integer, 1}},
      {:global_concurrency, fn -> 2 end, :limit},
      {:workspace_concurrency, fn -> 1 end, :limit},
      {:global_queue_limit, fn -> 100 end, :queue_limit},
      {:workspace_queue_limit, fn -> 20 end, :queue_limit},
      # Provider policy
      {:agent_delay_ms, fn -> 0 end, {:integer, 0}},
      {:allow_simulator_provider, fn -> false end, :boolean},
      {:default_provider, fn -> :unconfigured end, :atom},
      {:provider_discovery, fn -> true end, :boolean},
      {:provider_timeout_ms, fn -> 600_000 end, {:integer, 1}},
      {:provider_discovery_command_timeout_ms, fn -> 5_000 end, {:integer, 1}},
      {:provider_discovery_output_bytes, fn -> 256_000 end, {:integer, 1}},
      # OpenCode execution policy
      {:opencode_path, fn -> nil end, :optional_string},
      {:opencode_max_prompt_bytes, fn -> 128_000 end, {:integer, 1}},
      {:opencode_max_output_bytes, fn -> 10_000_000 end, {:integer, 1}},
      {:opencode_max_diagnostic_bytes, fn -> 64_000 end, {:integer, 1}},
      {:opencode_text_chunk_bytes, fn -> 8_192 end, {:integer, 1}},
      {:opencode_text_chunk_latency_ms, fn -> 50 end, {:integer, 0}},
      {:opencode_cpu_seconds, fn -> 900 end, {:integer, 1}},
      {:opencode_open_files, fn -> 1_024 end, {:integer, 1}},
      {:opencode_env_allowlist, fn -> [] end, {:list_of, :binary}},
      # OMP execution policy
      {:omp_path, fn -> nil end, :optional_string},
      {:omp_max_prompt_bytes, fn -> 128_000 end, {:integer, 1}},
      {:omp_max_output_bytes, fn -> 10_000_000 end, {:integer, 1}},
      {:omp_max_diagnostic_bytes, fn -> 64_000 end, {:integer, 1}},
      {:omp_text_chunk_bytes, fn -> 8_192 end, {:integer, 1}},
      {:omp_text_chunk_latency_ms, fn -> 50 end, {:integer, 0}},
      {:omp_cpu_seconds, fn -> 900 end, {:integer, 1}},
      {:omp_open_files, fn -> 1_024 end, {:integer, 1}},
      {:omp_env_allowlist, fn -> [] end, {:list_of, :binary}},
      {:omp_discovery_output_bytes, fn -> 1_048_576 end, {:integer, 1}},
      # OpenAI-compatible streaming policy
      {:openai_compatible_chunk_bytes, fn -> 8_192 end, {:integer, 1}},
      {:openai_compatible_chunk_latency_ms, fn -> 50 end, {:integer, 0}},
      {:openai_compatible_base_url_overrides, fn -> %{} end, :base_url_overrides},
      {:openai_compatible_providers, fn -> [] end, :provider_profiles},
      {:openai_compatible_transport, fn -> nil end, {:module_or_nil, nil}},
      # Squad workflow policy
      {:squad_release_gate_human, fn -> true end, :boolean},
      {:squad_rework_budget, fn -> Squad.max_rework() end, {:integer, 1}},
      {:squad_simulator, fn -> [] end, :simulator_options},
      # Event store / persistence policy
      {:projection_checkpoint_interval, fn -> 500 end, {:integer, 1}},
      {:max_replay_events, fn -> 2_000 end, {:integer, 1}},
      {:max_checkpoint_bytes, fn -> 67_108_864 end, {:integer, 1}},
      # Tool policy
      {:tool_bash_timeout_ms, fn -> 30_000 end, {:integer, 1}},
      {:tool_bash_max_output_bytes, fn -> 256_000 end, {:integer, 1}},
      {:tool_bash_max_error_bytes, fn -> 64_000 end, {:integer, 1}},
      {:tool_bash_env_allowlist, fn -> [] end, {:list_of, :binary}},
      {:tool_bash_cpu_seconds, fn -> 120 end, {:integer, 1}},
      {:tool_bash_open_files, fn -> 1_024 end, {:integer, 1}},
      {:tool_read_max_bytes, fn -> 512_000 end, {:integer, 1}},
      {:tool_read_max_lines, fn -> 2_000 end, {:integer, 1}},
      {:tool_edit_max_bytes, fn -> 512_000 end, {:integer, 1}},
      {:tool_write_max_bytes, fn -> 512_000 end, {:integer, 1}},
      {:tool_glob_max_results, fn -> 10_000 end, {:integer, 1}},
      {:tool_list_max_entries, fn -> 2_000 end, {:integer, 1}},
      {:tool_list_timeout_ms, fn -> 10_000 end, {:integer, 1}},
      {:tool_grep_max_matches, fn -> 1_000 end, {:integer, 1}},
      {:tool_grep_max_file_bytes, fn -> 512_000 end, {:integer, 1}},
      {:tool_grep_max_files, fn -> 10_000 end, {:integer, 1}},
      {:tool_grep_timeout_ms, fn -> 10_000 end, {:integer, 1}},
      {:workspace_roots, fn -> nil end, :optional_string_list},
      {:file_logging, fn -> false end, :boolean},
      {:log_dir, fn -> ReyCode.Paths.log_home() end, :string}
    ]
  end

  def defaults do
    Map.new(settings(), fn {key, default, _kind} -> {key, default.()} end)
  end

  def fresh(overrides) do
    defaults = defaults()
    overrides = Map.new(overrides)
    reject_unknown_overrides!(overrides, defaults)

    Map.new(settings(), fn {key, _default, kind} ->
      value = Map.get(overrides, key, Map.fetch!(defaults, key))
      {key, validate_kind!(key, value, kind)}
    end)
  end

  def load(fetch, environment_fetch)
      when is_function(fetch, 2) and is_function(environment_fetch, 1) do
    Map.new(settings(), fn {key, default, kind} ->
      {key, validate_kind!(key, fetch.(key, default.()), kind)}
    end)
    |> resolve_endpoint_overrides(environment_fetch)
  end

  # validation implementation
  ## Validation

  defp validate_kind!(_key, :infinity, kind) when kind in [:limit, :queue_limit], do: :infinity
  defp validate_kind!(key, value, :limit), do: bounded!(key, value, 1)
  defp validate_kind!(key, value, :queue_limit), do: bounded!(key, value, 0)

  defp validate_kind!(key, value, {:integer, minimum}) do
    if is_integer(value) and value >= minimum do
      value
    else
      raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected integer >= #{minimum})"
    end
  end

  defp validate_kind!(_key, value, :boolean) when is_boolean(value), do: value

  defp validate_kind!(key, value, :boolean) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected true or false)"
  end

  defp validate_kind!(_key, value, :atom) when is_atom(value), do: value

  defp validate_kind!(key, value, :atom) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected an atom)"
  end

  defp validate_kind!(_key, value, :string) when is_binary(value), do: value

  defp validate_kind!(key, value, :string) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a string path)"
  end

  defp validate_kind!(_key, nil, :optional_string), do: nil
  defp validate_kind!(_key, value, :optional_string) when is_binary(value), do: value

  defp validate_kind!(key, value, :optional_string) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a string path or nil)"
  end

  defp validate_kind!(_key, nil, :optional_string_list), do: nil
  defp validate_kind!(key, value, :optional_string_list), do: list_of!(key, value, :binary)

  defp validate_kind!(key, value, {:list_of, :binary}), do: list_of!(key, value, :binary)
  defp validate_kind!(key, value, :provider_profiles), do: provider_profiles!(key, value)

  defp validate_kind!(key, value, :base_url_overrides), do: base_url_overrides!(key, value)

  defp validate_kind!(key, value, :simulator_options), do: simulator_options!(key, value)

  defp validate_kind!(key, value, :keyword_list) when is_list(value) do
    if Keyword.keyword?(value) do
      value
    else
      raise ArgumentError, "invalid #{key}: expected a keyword list"
    end
  end

  defp validate_kind!(key, value, :keyword_list) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a keyword list)"
  end

  defp validate_kind!(_key, nil, {:module_or_nil, _fallback}), do: nil

  defp validate_kind!(key, value, {:module_or_nil, _fallback}) when is_atom(value) do
    if Code.ensure_loaded?(value), do: value, else: raise_invalid_module(key, value)
  end

  defp validate_kind!(key, value, {:module_or_nil, _fallback}) do
    raise_invalid_module(key, value)
  end

  defp list_of!(key, value, :binary) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: value,
      else: raise(ArgumentError, "invalid #{key}: expected a list of strings")
  end

  defp list_of!(key, value, _kind) when not is_list(value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a list)"
  end

  defp provider_profiles!(key, value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {profile, index} -> provider_profile!(key, profile, index) end)
  end

  defp provider_profiles!(key, value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a list of provider maps)"
  end

  defp base_url_overrides!(key, value) when is_map(value) do
    Map.new(value, fn
      {id, url} when is_atom(id) and is_binary(url) ->
        validate_http_url!("#{key}.#{id}", url)
        {id, url}

      entry ->
        raise ArgumentError,
              "invalid #{key}: #{inspect(entry)} (expected %{provider_atom => HTTP(S) URL})"
    end)
  end

  defp base_url_overrides!(key, value) do
    raise ArgumentError,
          "invalid #{key}: #{inspect(value)} (expected %{provider_atom => HTTP(S) URL})"
  end

  defp provider_profile!(key, profile, index) when is_map(profile) do
    path = "#{key}[#{index}]"
    id = required_profile_value!(profile, :id, path, &is_atom/1, "an atom")
    _name = required_profile_value!(profile, :name, path, &non_empty_string?/1, "a string")
    base_url = required_profile_value!(profile, :base_url, path, &is_binary/1, "an HTTP(S) URL")
    _key_env = required_profile_value!(profile, :key_env, path, &non_empty_string?/1, "a string")

    if id in [:opencode, :simulator, :demo, :unconfigured] do
      raise ArgumentError, "invalid #{path}.id: #{inspect(id)} (reserved provider id)"
    end

    validate_http_url!(path <> ".base_url", base_url)

    Enum.each([:request_timeout_ms, :max_output_bytes, :max_prompt_bytes], fn field ->
      case Map.fetch(profile, field) do
        :error -> :ok
        {:ok, value} -> bounded!("#{path}.#{field}", value, 1)
      end
    end)

    profile
  end

  defp provider_profile!(key, profile, index) do
    raise ArgumentError,
          "invalid #{key}[#{index}]: #{inspect(profile)} (expected a provider map)"
  end

  defp required_profile_value!(profile, field, path, predicate, expectation) do
    case Map.fetch(profile, field) do
      {:ok, value} ->
        if predicate.(value),
          do: value,
          else: raise(ArgumentError, "invalid #{path}.#{field}: expected #{expectation}")

      :error ->
        raise ArgumentError, "invalid #{path}.#{field}: required setting is missing"
    end
  end

  defp validate_http_url!(path, value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        validate_http_host!(path, value, host)

      _other ->
        raise ArgumentError, "invalid #{path}: #{inspect(value)} (expected an HTTP(S) URL)"
    end
  end

  defp validate_http_host!(path, value, host) do
    if String.valid?(host) and not String.match?(host, ~r/[\s\/?#]/u) do
      :ok
    else
      raise ArgumentError, "invalid #{path}: #{inspect(value)} (expected an HTTP(S) URL)"
    end
  end

  defp simulator_options!(key, value) when is_list(value) do
    if Keyword.keyword?(value) do
      allowed = [
        :seed,
        :delay_ms,
        :jitter_ms,
        :failure_rate,
        :failure_plan,
        :leader_rework_rounds,
        :rework_phase,
        :emit_process,
        :tool_requests
      ]

      unknown = Keyword.keys(value) -- allowed

      if unknown != [] do
        raise ArgumentError, "invalid #{key}: unknown options #{inspect(unknown)}"
      end

      validate_simulator_values!(key, value)
      value
    else
      raise ArgumentError, "invalid #{key}: expected a keyword list"
    end
  end

  defp simulator_options!(key, value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a keyword list)"
  end

  defp validate_simulator_values!(key, options) do
    validate_optional!(key, options, :seed, &is_integer/1, "an integer")

    Enum.each([:delay_ms, :jitter_ms, :leader_rework_rounds], fn field ->
      validate_optional!(key, options, field, &(is_integer(&1) and &1 >= 0), "an integer >= 0")
    end)

    validate_optional!(
      key,
      options,
      :failure_rate,
      &(is_number(&1) and &1 >= 0 and &1 <= 1),
      "a number between 0 and 1"
    )

    validate_optional!(key, options, :failure_plan, &valid_failure_plan?/1, "a failure map")
    validate_optional!(key, options, :rework_phase, &is_binary/1, "a string")
    validate_optional!(key, options, :emit_process, &(&1 in [:caller, :task]), ":caller or :task")

    validate_optional!(
      key,
      options,
      :tool_requests,
      &(is_list(&1) and Enum.all?(&1, fn request -> is_map(request) end)),
      "a list of maps"
    )
  end

  defp validate_optional!(key, options, field, predicate, expectation) do
    case Keyword.fetch(options, field) do
      :error ->
        :ok

      {:ok, value} ->
        if predicate.(value) do
          :ok
        else
          raise ArgumentError,
                "invalid #{key}.#{field}: #{inspect(value)} (expected #{expectation})"
        end
    end
  end

  defp valid_failure_plan?(plan) when is_map(plan) do
    allowed = [:retryable, :permanent, :crash, :timeout, :invalid_output, :after_frame]
    Enum.all?(Map.values(plan), &(&1 in allowed))
  end

  defp valid_failure_plan?(_plan), do: false

  defp reject_unknown_overrides!(overrides, defaults) do
    unknown = Map.keys(overrides) -- Map.keys(defaults)

    if unknown != [] do
      raise ArgumentError,
            "unknown runtime configuration overrides: #{inspect(Enum.sort(unknown))}"
    end
  end

  defp resolve_endpoint_overrides(values, environment_fetch) do
    provider_ids =
      [:deepseek | Enum.map(values.openai_compatible_providers, &Map.fetch!(&1, :id))]

    environment_overrides =
      Map.new(provider_ids, fn id ->
        environment_name = "REYCODE_#{id |> Atom.to_string() |> String.upcase()}_BASE_URL"
        {id, environment_fetch.(environment_name)}
      end)
      |> Map.reject(fn {_id, value} -> is_nil(value) end)
      |> then(&base_url_overrides!(:openai_compatible_base_url_overrides, &1))

    Map.update!(values, :openai_compatible_base_url_overrides, fn configured ->
      Map.merge(configured, environment_overrides)
    end)
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp bounded!(_key, value, minimum) when is_integer(value) and value >= minimum, do: value

  defp bounded!(key, value, minimum) do
    raise ArgumentError,
          "invalid #{key}: #{inspect(value)} (expected :infinity or integer >= #{minimum})"
  end

  defp raise_invalid_module(key, value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a loaded module or nil)"
  end
end
