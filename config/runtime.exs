import Config

if config_env() == :prod do
  parse_integer = fn name, default, minimum ->
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer >= minimum -> integer
          _other -> raise "#{name} must be an integer greater than or equal to #{minimum}"
        end
    end
  end

  parse_boolean = fn name, default ->
    case System.get_env(name) do
      nil -> default
      "true" -> true
      "false" -> false
      _value -> raise "#{name} must be true or false"
    end
  end

  split_list = fn name ->
    name
    |> System.get_env("")
    |> String.split([",", ":"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  data_dir =
    System.get_env("REYCODE_DATA_DIR") ||
      Path.expand("~/Library/Application Support/ReyCode")

  log_dir = System.get_env("REYCODE_LOG_DIR") || Path.expand("~/Library/Logs/ReyCode")
  mode = System.get_env("REYCODE_MODE", "local")

  if mode != "local" do
    raise "REYCODE_MODE=#{mode} is not supported by this local release"
  end

  values = [
    mode: :local,
    data_dir: data_dir,
    log_dir: log_dir,
    opencode_path: System.get_env("REYCODE_OPENCODE_PATH"),
    opencode_env_allowlist: split_list.("REYCODE_OPENCODE_ENV_ALLOWLIST"),
    omp_path: System.get_env("REYCODE_OMP_PATH"),
    omp_env_allowlist: split_list.("REYCODE_OMP_ENV_ALLOWLIST"),
    global_concurrency: parse_integer.("REYCODE_GLOBAL_CONCURRENCY", 2, 1),
    context_budget_tokens: parse_integer.("REYCODE_CONTEXT_BUDGET_TOKENS", 200_000, 1_000),
    workspace_concurrency: parse_integer.("REYCODE_WORKSPACE_CONCURRENCY", 1, 1),
    global_queue_limit: parse_integer.("REYCODE_GLOBAL_QUEUE_LIMIT", 100, 0),
    workspace_queue_limit: parse_integer.("REYCODE_WORKSPACE_QUEUE_LIMIT", 20, 0),
    tui_reduced_motion: parse_boolean.("REYCODE_TUI_REDUCED_MOTION", false),
    steering_max_pending: parse_integer.("REYCODE_STEERING_MAX_PENDING", 8, 1),
    steering_max_bytes: parse_integer.("REYCODE_STEERING_MAX_BYTES", 16_384, 1),
    tool_lsp_command: split_list.("REYCODE_TOOL_LSP_COMMAND"),
    tool_lsp_env_allowlist: split_list.("REYCODE_TOOL_LSP_ENV_ALLOWLIST"),
    tool_lsp_timeout_ms: parse_integer.("REYCODE_TOOL_LSP_TIMEOUT_MS", 5_000, 1),
    tool_lsp_max_output_bytes: parse_integer.("REYCODE_TOOL_LSP_MAX_OUTPUT_BYTES", 1_000_000, 1),
    tool_lsp_max_file_bytes: parse_integer.("REYCODE_TOOL_LSP_MAX_FILE_BYTES", 2_000_000, 1),
    tool_lsp_max_edits: parse_integer.("REYCODE_TOOL_LSP_MAX_EDITS", 256, 1),
    tool_lsp_cpu_seconds: parse_integer.("REYCODE_TOOL_LSP_CPU_SECONDS", 30, 1),
    tool_lsp_open_files: parse_integer.("REYCODE_TOOL_LSP_OPEN_FILES", 1_024, 64),
    tool_process_max_processes: parse_integer.("REYCODE_TOOL_PROCESS_MAX_PROCESSES", 8, 1),
    tool_process_max_output_bytes:
      parse_integer.("REYCODE_TOOL_PROCESS_MAX_OUTPUT_BYTES", 1_000_000, 1),
    tool_process_stop_timeout_ms:
      parse_integer.("REYCODE_TOOL_PROCESS_STOP_TIMEOUT_MS", 2_000, 1),
    tool_process_env_allowlist: split_list.("REYCODE_TOOL_PROCESS_ENV_ALLOWLIST"),
    tool_process_cpu_seconds: parse_integer.("REYCODE_TOOL_PROCESS_CPU_SECONDS", 900, 1),
    tool_process_open_files: parse_integer.("REYCODE_TOOL_PROCESS_OPEN_FILES", 1_024, 64),
    tool_debugger_command: split_list.("REYCODE_TOOL_DEBUGGER_COMMAND"),
    tool_debugger_timeout_ms: parse_integer.("REYCODE_TOOL_DEBUGGER_TIMEOUT_MS", 10_000, 1),
    tool_debugger_max_output_bytes:
      parse_integer.("REYCODE_TOOL_DEBUGGER_MAX_OUTPUT_BYTES", 1_000_000, 1),
    tool_debugger_env_allowlist: split_list.("REYCODE_TOOL_DEBUGGER_ENV_ALLOWLIST"),
    tool_debugger_cpu_seconds: parse_integer.("REYCODE_TOOL_DEBUGGER_CPU_SECONDS", 120, 1),
    tool_debugger_open_files: parse_integer.("REYCODE_TOOL_DEBUGGER_OPEN_FILES", 1_024, 64),
    opencode_max_prompt_bytes: parse_integer.("REYCODE_MAX_PROMPT_BYTES", 128_000, 1_024),
    opencode_max_output_bytes: parse_integer.("REYCODE_MAX_OUTPUT_BYTES", 2_000_000, 1_024),
    opencode_max_diagnostic_bytes: parse_integer.("REYCODE_MAX_DIAGNOSTIC_BYTES", 64_000, 1_024),
    opencode_text_chunk_bytes: parse_integer.("REYCODE_TEXT_CHUNK_BYTES", 8_192, 256),
    opencode_text_chunk_latency_ms: parse_integer.("REYCODE_TEXT_CHUNK_LATENCY_MS", 50, 0),
    web_search_endpoint: System.get_env("REYCODE_WEB_SEARCH_ENDPOINT"),
    web_search_key_env: System.get_env("REYCODE_WEB_SEARCH_KEY_ENV"),
    web_search_timeout_ms: parse_integer.("REYCODE_WEB_SEARCH_TIMEOUT_MS", 10_000, 1),
    web_search_max_results: parse_integer.("REYCODE_WEB_SEARCH_MAX_RESULTS", 10, 1),
    web_search_max_bytes: parse_integer.("REYCODE_WEB_SEARCH_MAX_BYTES", 1_000_000, 1),
    document_read_timeout_ms: parse_integer.("REYCODE_DOCUMENT_READ_TIMEOUT_MS", 15_000, 1),
    opencode_open_files: parse_integer.("REYCODE_OPENCODE_OPEN_FILES", 1_024, 64),
    omp_max_prompt_bytes: parse_integer.("REYCODE_OMP_MAX_PROMPT_BYTES", 128_000, 1_024),
    omp_max_output_bytes: parse_integer.("REYCODE_OMP_MAX_OUTPUT_BYTES", 2_000_000, 1_024),
    omp_max_diagnostic_bytes: parse_integer.("REYCODE_OMP_MAX_DIAGNOSTIC_BYTES", 64_000, 1_024),
    omp_text_chunk_bytes: parse_integer.("REYCODE_OMP_TEXT_CHUNK_BYTES", 8_192, 256),
    omp_text_chunk_latency_ms: parse_integer.("REYCODE_OMP_TEXT_CHUNK_LATENCY_MS", 50, 0),
    omp_cpu_seconds: parse_integer.("REYCODE_OMP_CPU_SECONDS", 900, 1),
    omp_open_files: parse_integer.("REYCODE_OMP_OPEN_FILES", 1_024, 64),
    omp_discovery_output_bytes:
      parse_integer.("REYCODE_OMP_DISCOVERY_OUTPUT_BYTES", 1_048_576, 1),
    projection_checkpoint_interval: parse_integer.("REYCODE_CHECKPOINT_INTERVAL", 500, 1),
    max_replay_events: parse_integer.("REYCODE_MAX_REPLAY_EVENTS", 2_000, 1),
    max_checkpoint_bytes: parse_integer.("REYCODE_MAX_CHECKPOINT_BYTES", 67_108_864, 1_024)
  ]

  workspace_roots = split_list.("REYCODE_WORKSPACE_ROOTS")

  values =
    if workspace_roots == [],
      do: values,
      else: Keyword.put(values, :workspace_roots, workspace_roots)

  config :rey_code, values
end
