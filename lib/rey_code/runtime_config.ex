defmodule ReyCode.RuntimeConfig do
  @moduledoc """
  One authoritative, validated runtime configuration for ReyCode.

  The external schema remains flat because application and environment keys
  are a stable deployment boundary. After validation, settings are assembled
  into focused immutable policy records so runtime consumers depend only on
  the concern they use. Provider credentials are resolved from the environment
  at invocation time and are never part of this value.

  Bootstrap-only settings (`event_path`, `data_dir`, `start_tui`) are read
  directly by `ReyCode.Application` while assembling the supervision tree.
  """

  alias ReyCode.RuntimeConfig.{
    Logging,
    OMP,
    OpenAICompatible,
    OpenCode,
    Orchestration,
    Persistence,
    Providers,
    Schema,
    Simulator,
    Squad,
    Tools,
    Workspace
  }

  @enforce_keys [
    :orchestration,
    :providers,
    :open_code,
    :omp,
    :open_ai,
    :squad,
    :persistence,
    :tools,
    :workspace,
    :logging
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          orchestration: Orchestration.t(),
          providers: Providers.t(),
          open_code: OpenCode.t(),
          omp: OMP.t(),
          open_ai: OpenAICompatible.t(),
          squad: Squad.t(),
          persistence: Persistence.t(),
          tools: Tools.t(),
          workspace: Workspace.t(),
          logging: Logging.t()
        }

  @doc "Returns every external setting as `%{key => default}` without reading the environment."
  @spec declared_defaults() :: %{atom() => term()}
  def declared_defaults, do: Schema.defaults()

  @doc """
  Builds validated focused policies from flat explicit overrides.

  Missing keys resolve to declared defaults rather than application or process
  environment values. Isolated component stacks use this to pin exactly the
  policy under test.
  """
  @spec fresh(keyword() | map()) :: t()
  def fresh(overrides \\ []) do
    overrides
    |> Schema.fresh()
    |> assemble()
  end

  @doc """
  Loads every flat external setting once, validates it, and assembles focused
  immutable runtime policies. Raises an ArgumentError naming the external key
  when invalid.
  """
  @spec load!() :: t()
  def load! do
    load(&Application.get_env(:rey_code, &1, &2), &System.get_env/1)
  end

  @doc """
  Loads configuration from an explicit settings source — the injection seam
  for tests and embedded startups. Secrets still resolve through `env`;
  credential values never become part of the resulting struct.
  """
  @spec load((atom(), term() -> term()), (String.t() -> String.t() | nil)) :: t()
  def load(source, env \\ &System.get_env/1) do
    source
    |> Schema.load(env)
    |> assemble()
  end

  @doc "Validates configuration for side-effectful startup, returning `:ok`."
  @spec validate!() :: :ok
  def validate! do
    _config = load!()
    :ok
  end

  @doc "Builds the focused deterministic simulator policy used by provider runtimes."
  @spec simulator_policy(t()) :: Simulator.t()
  def simulator_policy(%__MODULE__{} = config) do
    %Simulator{
      agent_delay_ms: config.orchestration.agent_delay_ms,
      options: config.squad.simulator
    }
  end

  defp assemble(values) do
    %__MODULE__{
      orchestration: %Orchestration{
        context_budget_tokens: values.context_budget_tokens,
        global_concurrency: values.global_concurrency,
        workspace_concurrency: values.workspace_concurrency,
        global_queue_limit: values.global_queue_limit,
        workspace_queue_limit: values.workspace_queue_limit,
        agent_delay_ms: values.agent_delay_ms
      },
      providers: %Providers{
        allow_simulator?: values.allow_simulator_provider,
        default_provider: values.default_provider,
        discovery?: values.provider_discovery,
        discovery_command_timeout_ms: values.provider_discovery_command_timeout_ms,
        discovery_output_bytes: values.provider_discovery_output_bytes
      },
      open_code: %OpenCode{
        path: values.opencode_path,
        provider_timeout_ms: values.provider_timeout_ms,
        max_prompt_bytes: values.opencode_max_prompt_bytes,
        max_output_bytes: values.opencode_max_output_bytes,
        max_diagnostic_bytes: values.opencode_max_diagnostic_bytes,
        text_chunk_bytes: values.opencode_text_chunk_bytes,
        text_chunk_latency_ms: values.opencode_text_chunk_latency_ms,
        cpu_seconds: values.opencode_cpu_seconds,
        open_files: values.opencode_open_files,
        env_allowlist: values.opencode_env_allowlist
      },
      omp: %OMP{
        path: values.omp_path,
        provider_timeout_ms: values.provider_timeout_ms,
        max_prompt_bytes: values.omp_max_prompt_bytes,
        max_output_bytes: values.omp_max_output_bytes,
        max_diagnostic_bytes: values.omp_max_diagnostic_bytes,
        text_chunk_bytes: values.omp_text_chunk_bytes,
        text_chunk_latency_ms: values.omp_text_chunk_latency_ms,
        cpu_seconds: values.omp_cpu_seconds,
        open_files: values.omp_open_files,
        env_allowlist: values.omp_env_allowlist,
        discovery_output_bytes: values.omp_discovery_output_bytes
      },
      open_ai: %OpenAICompatible{
        chunk_bytes: values.openai_compatible_chunk_bytes,
        chunk_latency_ms: values.openai_compatible_chunk_latency_ms,
        base_url_overrides: values.openai_compatible_base_url_overrides,
        profiles: values.openai_compatible_providers,
        transport: values.openai_compatible_transport
      },
      squad: %Squad{
        release_gate_human?: values.squad_release_gate_human,
        rework_budget: values.squad_rework_budget,
        simulator: values.squad_simulator
      },
      persistence: %Persistence{
        checkpoint_interval: values.projection_checkpoint_interval,
        max_replay_events: values.max_replay_events,
        max_checkpoint_bytes: values.max_checkpoint_bytes
      },
      tools: %Tools{
        bash: %Tools.Bash{
          timeout_ms: values.tool_bash_timeout_ms,
          max_output_bytes: values.tool_bash_max_output_bytes,
          max_error_bytes: values.tool_bash_max_error_bytes,
          env_allowlist: values.tool_bash_env_allowlist,
          cpu_seconds: values.tool_bash_cpu_seconds,
          open_files: values.tool_bash_open_files
        },
        read: %Tools.Read{
          max_bytes: values.tool_read_max_bytes,
          max_lines: values.tool_read_max_lines
        },
        edit: %Tools.Edit{max_bytes: values.tool_edit_max_bytes},
        write: %Tools.Write{max_bytes: values.tool_write_max_bytes},
        glob: %Tools.Glob{max_results: values.tool_glob_max_results},
        list: %Tools.List{
          max_entries: values.tool_list_max_entries,
          timeout_ms: values.tool_list_timeout_ms
        },
        grep: %Tools.Grep{
          max_matches: values.tool_grep_max_matches,
          max_file_bytes: values.tool_grep_max_file_bytes,
          max_files: values.tool_grep_max_files,
          timeout_ms: values.tool_grep_timeout_ms
        }
      },
      workspace: %Workspace{roots: values.workspace_roots},
      logging: %Logging{enabled?: values.file_logging, log_dir: values.log_dir}
    }
  end
end
