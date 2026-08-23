defmodule ReyCode.RuntimeConfig do
  @moduledoc """
  One authoritative, validated runtime configuration for ReyCode.

  `load!/0` reads the configured application environment once, validates
  every declared setting against its type and bounds, and returns an
  immutable struct that startup injects into long-lived processes. Provider
  credentials are never part of this value; they are resolved from the
  environment at invocation time.

  Bootstrap-only settings (`event_path`, `data_dir`, `start_tui`) are read
  directly by `ReyCode.Application` while assembling the supervision tree
  and intentionally have no entry here.
  """

  @enforce_keys [
    :agent_delay_ms,
    :allow_simulator_provider,
    :default_provider,
    :file_logging,
    :global_concurrency,
    :global_queue_limit,
    :log_dir,
    :max_checkpoint_bytes,
    :max_replay_events,
    :openai_compatible_chunk_bytes,
    :openai_compatible_chunk_latency_ms,
    :openai_compatible_providers,
    :openai_compatible_transport,
    :opencode_cpu_seconds,
    :opencode_env_allowlist,
    :opencode_max_diagnostic_bytes,
    :opencode_max_output_bytes,
    :opencode_max_prompt_bytes,
    :opencode_open_files,
    :opencode_path,
    :opencode_text_chunk_bytes,
    :opencode_text_chunk_latency_ms,
    :projection_checkpoint_interval,
    :provider_discovery,
    :provider_discovery_command_timeout_ms,
    :provider_discovery_output_bytes,
    :provider_timeout_ms,
    :squad_release_gate_human,
    :squad_rework_budget,
    :squad_simulator,
    :tool_bash_cpu_seconds,
    :tool_bash_env_allowlist,
    :tool_bash_max_error_bytes,
    :tool_bash_max_output_bytes,
    :tool_bash_open_files,
    :tool_bash_timeout_ms,
    :tool_edit_max_bytes,
    :tool_glob_max_results,
    :tool_grep_max_file_bytes,
    :tool_grep_max_matches,
    :tool_read_max_bytes,
    :tool_read_max_lines,
    :tool_write_max_bytes,
    :workspace_concurrency,
    :workspace_queue_limit,
    :workspace_roots
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  # {key, default-lambda, kind} — validated by validate_kind!/3.
  alias ReyCode.Orchestration.Squad

  defp settings do
    [
      # Orchestration limits
      {:global_concurrency, fn -> :infinity end, :limit},
      {:workspace_concurrency, fn -> :infinity end, :limit},
      {:global_queue_limit, fn -> :infinity end, :queue_limit},
      {:workspace_queue_limit, fn -> :infinity end, :queue_limit},
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
      # OpenAI-compatible streaming policy
      {:openai_compatible_chunk_bytes, fn -> 8_192 end, {:integer, 1}},
      {:openai_compatible_chunk_latency_ms, fn -> 50 end, {:integer, 0}},
      {:openai_compatible_providers, fn -> [] end, {:list_of, :map}},
      {:openai_compatible_transport, fn -> nil end, {:module_or_nil, nil}},
      # Squad workflow policy
      {:squad_release_gate_human, fn -> true end, :boolean},
      {:squad_rework_budget, fn -> Squad.max_rework() end, {:integer, 1}},
      {:squad_simulator, fn -> [] end, :keyword_list},
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
      {:tool_grep_max_matches, fn -> 1_000 end, {:integer, 1}},
      {:tool_grep_max_file_bytes, fn -> 512_000 end, {:integer, 1}},
      # Security, logging, system
      {:workspace_roots, fn -> nil end, :optional_string_list},
      {:file_logging, fn -> false end, :boolean},
      {:log_dir, fn -> Path.expand("~/Library/Logs/ReyCode") end, :string}
    ]
  end

  @doc "Returns every declared setting as `%{key => default}` without reading the environment."
  @spec declared_defaults() :: %{atom() => term()}
  def declared_defaults do
    Map.new(settings(), fn {key, default, _kind} -> {key, default.()} end)
  end

  @doc """
  Loads and validates the runtime configuration, returning an immutable
  struct. Raises an ArgumentError naming the offending setting when invalid.
  """
  @spec load!() :: t()
  def load! do
    values =
      Map.new(settings(), fn {key, default, kind} ->
        {key, validate_kind!(key, Application.get_env(:rey_code, key, default.()), kind)}
      end)

    struct!(__MODULE__, values)
  end

  @doc "Validates the configuration for side-effectful startup, returning `:ok`."
  @spec validate!() :: :ok
  def validate! do
    _ = load!()
    :ok
  end

  @doc """
  Reads one setting from an injected config struct.

  A nil injected value falls back to the application environment so
  components can run un-injected (tests, scripts) during migration.
  """
  @spec policy(t() | nil, atom(), term()) :: term()
  def policy(nil, key, default), do: Application.get_env(:rey_code, key, default)
  def policy(config, key, _default) when is_map(config), do: Map.fetch!(config, key)

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
  defp validate_kind!(key, value, {:list_of, :map}), do: list_of!(key, value, :map)

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

  defp list_of!(key, value, :map) when is_list(value) do
    if Enum.all?(value, &is_map/1),
      do: value,
      else: raise(ArgumentError, "invalid #{key}: expected a list of provider maps")
  end

  defp list_of!(key, value, _kind) when not is_list(value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a list)"
  end

  defp bounded!(_key, value, minimum) when is_integer(value) and value >= minimum, do: value

  defp bounded!(key, value, minimum) do
    raise ArgumentError,
          "invalid #{key}: #{inspect(value)} (expected :infinity or integer >= #{minimum})"
  end

  defp raise_invalid_module(key, value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)} (expected a loaded module or nil)"
  end
end
