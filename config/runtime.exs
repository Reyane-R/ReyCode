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
    global_concurrency: parse_integer.("REYCODE_GLOBAL_CONCURRENCY", 2, 1),
    workspace_concurrency: parse_integer.("REYCODE_WORKSPACE_CONCURRENCY", 1, 1),
    global_queue_limit: parse_integer.("REYCODE_GLOBAL_QUEUE_LIMIT", 100, 0),
    workspace_queue_limit: parse_integer.("REYCODE_WORKSPACE_QUEUE_LIMIT", 20, 0),
    provider_timeout_ms: parse_integer.("REYCODE_PROVIDER_TIMEOUT_MS", 600_000, 1_000),
    opencode_max_prompt_bytes: parse_integer.("REYCODE_MAX_PROMPT_BYTES", 128_000, 1_024),
    opencode_max_output_bytes: parse_integer.("REYCODE_MAX_OUTPUT_BYTES", 2_000_000, 1_024),
    opencode_max_diagnostic_bytes: parse_integer.("REYCODE_MAX_DIAGNOSTIC_BYTES", 64_000, 1_024),
    opencode_text_chunk_bytes: parse_integer.("REYCODE_TEXT_CHUNK_BYTES", 8_192, 256),
    opencode_text_chunk_latency_ms: parse_integer.("REYCODE_TEXT_CHUNK_LATENCY_MS", 50, 0),
    opencode_cpu_seconds: parse_integer.("REYCODE_OPENCODE_CPU_SECONDS", 900, 1),
    opencode_open_files: parse_integer.("REYCODE_OPENCODE_OPEN_FILES", 1_024, 64),
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
