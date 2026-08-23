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

  alias ReyCode.RuntimeConfig.Schema

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
    :openai_compatible_base_url_overrides,
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
    :tool_grep_max_files,
    :tool_grep_max_matches,
    :tool_grep_timeout_ms,
    :tool_list_max_entries,
    :tool_list_timeout_ms,
    :tool_read_max_bytes,
    :tool_read_max_lines,
    :tool_write_max_bytes,
    :workspace_concurrency,
    :workspace_queue_limit,
    :workspace_roots
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc "Returns every declared setting as `%{key => default}` without reading the environment."
  @spec declared_defaults() :: %{atom() => term()}
  def declared_defaults, do: Schema.defaults()

  @doc """
  Builds a validated configuration from explicit overrides alone.

  Unlike `load!/0`, missing keys resolve to their declared defaults rather
  than the application environment, and nothing is read from or written to
  the environment. Isolated component stacks use this to pin exactly the
  policy under test.
  """
  @spec fresh(keyword() | map()) :: t()
  def fresh(overrides \\ []) do
    struct!(__MODULE__, Schema.fresh(overrides))
  end

  @doc """
  Loads and validates the runtime configuration, returning an immutable
  struct. Raises an ArgumentError naming the offending setting when invalid.
  """
  @spec load!() :: t()
  def load! do
    values = Schema.load(&Application.get_env(:rey_code, &1, &2), &System.get_env/1)
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
  """
  @spec policy(t() | nil, atom(), term()) :: term()
  def policy(nil, _key, default), do: default
  def policy(config, key, _default) when is_map(config), do: Map.fetch!(config, key)
end
