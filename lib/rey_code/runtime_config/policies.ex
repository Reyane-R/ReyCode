defmodule ReyCode.RuntimeConfig.Orchestration do
  @moduledoc "Concurrency, queueing, and pacing policy for orchestration."

  @enforce_keys [
    :context_budget_tokens,
    :global_concurrency,
    :workspace_concurrency,
    :global_queue_limit,
    :workspace_queue_limit,
    :agent_delay_ms,
    :delegation_max_children,
    :delegation_brief_max_bytes,
    :steering_max_pending,
    :steering_max_bytes
  ]

  defstruct @enforce_keys

  @type limit :: pos_integer() | :infinity
  @type queue_limit :: non_neg_integer() | :infinity

  @type t :: %__MODULE__{
          context_budget_tokens: pos_integer(),
          global_concurrency: limit(),
          workspace_concurrency: limit(),
          global_queue_limit: queue_limit(),
          agent_delay_ms: non_neg_integer(),
          delegation_max_children: pos_integer(),
          delegation_brief_max_bytes: pos_integer(),
          steering_max_pending: pos_integer(),
          steering_max_bytes: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Providers do
  @moduledoc "Provider selection and discovery policy."

  @enforce_keys [
    :allow_simulator?,
    :default_provider,
    :discovery?,
    :discovery_command_timeout_ms,
    :discovery_output_bytes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          allow_simulator?: boolean(),
          default_provider: atom(),
          discovery?: boolean(),
          discovery_command_timeout_ms: pos_integer(),
          discovery_output_bytes: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.OpenCode do
  @moduledoc "OpenCode process, resource, and streaming policy."

  @enforce_keys [
    :path,
    :provider_timeout_ms,
    :max_prompt_bytes,
    :max_output_bytes,
    :max_diagnostic_bytes,
    :text_chunk_bytes,
    :text_chunk_latency_ms,
    :cpu_seconds,
    :open_files,
    :env_allowlist
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: String.t() | nil,
          provider_timeout_ms: pos_integer(),
          max_prompt_bytes: pos_integer(),
          max_output_bytes: pos_integer(),
          max_diagnostic_bytes: pos_integer(),
          text_chunk_bytes: pos_integer(),
          text_chunk_latency_ms: non_neg_integer(),
          cpu_seconds: pos_integer(),
          open_files: pos_integer(),
          env_allowlist: [String.t()]
        }
end

defmodule ReyCode.RuntimeConfig.OMP do
  @moduledoc "OMP process, resource, and streaming policy."

  @enforce_keys [
    :path,
    :provider_timeout_ms,
    :max_prompt_bytes,
    :max_output_bytes,
    :max_diagnostic_bytes,
    :text_chunk_bytes,
    :text_chunk_latency_ms,
    :cpu_seconds,
    :open_files,
    :env_allowlist,
    :discovery_output_bytes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: String.t() | nil,
          provider_timeout_ms: pos_integer(),
          max_prompt_bytes: pos_integer(),
          max_output_bytes: pos_integer(),
          max_diagnostic_bytes: pos_integer(),
          text_chunk_bytes: pos_integer(),
          text_chunk_latency_ms: non_neg_integer(),
          cpu_seconds: pos_integer(),
          open_files: pos_integer(),
          env_allowlist: [String.t()],
          discovery_output_bytes: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.OpenAICompatible do
  @moduledoc "OpenAI-compatible profiles, transport, endpoints, and chunking policy."

  @enforce_keys [
    :chunk_bytes,
    :chunk_latency_ms,
    :base_url_overrides,
    :capability_overrides,
    :profiles,
    :transport
  ]
  defstruct @enforce_keys

  @type capability :: %{
          optional(:supports_tools) => boolean(),
          optional(:supports_stream_options) => boolean()
        }

  @type t :: %__MODULE__{
          chunk_bytes: pos_integer(),
          chunk_latency_ms: non_neg_integer(),
          base_url_overrides: map(),
          capability_overrides: %{optional(atom()) => capability()},
          profiles: [map()],
          transport: module() | nil
        }
end

defmodule ReyCode.RuntimeConfig.Squad do
  @moduledoc "Squad workflow, release, rework, and simulator policy."

  @enforce_keys [:release_gate_human?, :rework_budget, :simulator]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          release_gate_human?: boolean(),
          rework_budget: pos_integer(),
          simulator: keyword()
        }
end

defmodule ReyCode.RuntimeConfig.Persistence do
  @moduledoc "Projection checkpoint and replay policy."

  @enforce_keys [:checkpoint_interval, :max_replay_events, :max_checkpoint_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          checkpoint_interval: pos_integer(),
          max_replay_events: pos_integer(),
          max_checkpoint_bytes: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.Bash do
  @moduledoc "Bash tool execution limits and environment policy."

  @enforce_keys [
    :timeout_ms,
    :max_output_bytes,
    :max_error_bytes,
    :env_allowlist,
    :cpu_seconds,
    :open_files
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          max_error_bytes: pos_integer(),
          env_allowlist: [String.t()],
          cpu_seconds: pos_integer(),
          open_files: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.Read do
  @moduledoc "Read tool byte and line limits."

  @enforce_keys [:max_bytes, :max_lines]
  defstruct @enforce_keys

  @type t :: %__MODULE__{max_bytes: pos_integer(), max_lines: pos_integer()}
end

defmodule ReyCode.RuntimeConfig.Tools.Edit do
  @moduledoc "Hash-anchored atomic edit limits."

  @enforce_keys [:max_bytes, :max_patches]
  defstruct @enforce_keys

  @type t :: %__MODULE__{max_bytes: pos_integer(), max_patches: pos_integer()}
end

defmodule ReyCode.RuntimeConfig.Tools.Write do
  @moduledoc "Write tool byte limit."

  @enforce_keys [:max_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{max_bytes: pos_integer()}
end

defmodule ReyCode.RuntimeConfig.Tools.Glob do
  @moduledoc "Glob tool result limit."

  @enforce_keys [:max_results]
  defstruct @enforce_keys

  @type t :: %__MODULE__{max_results: pos_integer()}
end

defmodule ReyCode.RuntimeConfig.Tools.List do
  @moduledoc "Directory-listing result and timeout limits."

  @enforce_keys [:max_entries, :timeout_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{max_entries: pos_integer(), timeout_ms: pos_integer()}
end

defmodule ReyCode.RuntimeConfig.Tools.Grep do
  @moduledoc "Grep result, input, and timeout limits."

  @enforce_keys [:max_matches, :max_file_bytes, :max_files, :timeout_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          max_matches: pos_integer(),
          max_file_bytes: pos_integer(),
          max_files: pos_integer(),
          timeout_ms: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.LSP do
  @moduledoc "Language-server command, resource, and result limits."

  @enforce_keys [
    :command,
    :timeout_ms,
    :max_output_bytes,
    :max_file_bytes,
    :max_edits,
    :env_allowlist,
    :cpu_seconds,
    :open_files
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          command: [String.t()],
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          max_edits: pos_integer(),
          env_allowlist: [String.t()],
          cpu_seconds: pos_integer(),
          open_files: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.BackgroundProcess do
  @moduledoc "Supervised background-process admission and resource limits."

  @enforce_keys [
    :max_processes,
    :max_output_bytes,
    :stop_timeout_ms,
    :env_allowlist,
    :cpu_seconds,
    :open_files
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          max_processes: pos_integer(),
          max_output_bytes: pos_integer(),
          stop_timeout_ms: pos_integer(),
          env_allowlist: [String.t()],
          cpu_seconds: pos_integer(),
          open_files: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.Debugger do
  @moduledoc "Debug Adapter Protocol command and request limits."

  @enforce_keys [
    :command,
    :timeout_ms,
    :max_output_bytes,
    :env_allowlist,
    :cpu_seconds,
    :open_files
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          command: [String.t()],
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          env_allowlist: [String.t()],
          cpu_seconds: pos_integer(),
          open_files: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.Research do
  @moduledoc "Bounded web search and document-fetch policy."

  @enforce_keys [
    :search_endpoint,
    :search_key_env,
    :search_timeout_ms,
    :max_results,
    :max_bytes,
    :document_timeout_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          search_endpoint: String.t() | nil,
          search_key_env: String.t() | nil,
          search_timeout_ms: pos_integer(),
          max_results: pos_integer(),
          max_bytes: pos_integer(),
          document_timeout_ms: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools.Evaluation do
  @moduledoc "Persistent evaluation kernel limits and runtime commands."

  @enforce_keys [
    :python_command,
    :javascript_command,
    :timeout_ms,
    :max_code_bytes,
    :max_output_bytes,
    :max_kernels,
    :env_allowlist,
    :cpu_seconds,
    :open_files
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          python_command: [String.t()],
          javascript_command: [String.t()],
          timeout_ms: pos_integer(),
          max_code_bytes: pos_integer(),
          max_output_bytes: pos_integer(),
          max_kernels: pos_integer(),
          env_allowlist: [String.t()],
          cpu_seconds: pos_integer(),
          open_files: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Tools do
  @moduledoc "Focused policies for each executable tool."

  alias ReyCode.RuntimeConfig.Tools.{
    BackgroundProcess,
    Bash,
    Debugger,
    Edit,
    Evaluation,
    Glob,
    Grep,
    List,
    LSP,
    Read,
    Research,
    Write
  }

  @enforce_keys [
    :bash,
    :read,
    :edit,
    :write,
    :glob,
    :list,
    :grep,
    :lsp,
    :process,
    :debugger,
    :evaluation,
    :research
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          bash: Bash.t(),
          read: Read.t(),
          edit: Edit.t(),
          write: Write.t(),
          glob: Glob.t(),
          list: List.t(),
          grep: Grep.t(),
          lsp: LSP.t(),
          process: BackgroundProcess.t(),
          debugger: Debugger.t(),
          evaluation: Evaluation.t(),
          research: Research.t()
        }
end

defmodule ReyCode.RuntimeConfig.Simulator do
  @moduledoc "Deterministic simulator pacing and scenario policy."

  @enforce_keys [:agent_delay_ms, :options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{agent_delay_ms: non_neg_integer(), options: keyword()}
end

defmodule ReyCode.RuntimeConfig.Workspace do
  @moduledoc "Trusted workspace-root policy."

  @enforce_keys [:roots]
  defstruct @enforce_keys

  @type t :: %__MODULE__{roots: [String.t()] | nil}
end

defmodule ReyCode.RuntimeConfig.Artifacts do
  @moduledoc "Bounded durable tool-output artifact policy."

  @enforce_keys [
    :root,
    :spool_threshold_bytes,
    :preview_bytes,
    :max_artifact_bytes,
    :max_artifact_count
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          root: String.t(),
          spool_threshold_bytes: pos_integer(),
          preview_bytes: pos_integer(),
          max_artifact_bytes: pos_integer(),
          max_artifact_count: pos_integer()
        }
end

defmodule ReyCode.RuntimeConfig.Logging do
  @moduledoc "File logging policy."

  @enforce_keys [:enabled?, :log_dir]
  defstruct @enforce_keys

  @type t :: %__MODULE__{enabled?: boolean(), log_dir: String.t()}
end

defmodule ReyCode.RuntimeConfig.TUI do
  @moduledoc "Terminal presentation and accessibility policy."

  @enforce_keys [:reduced_motion?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{reduced_motion?: boolean()}
end
