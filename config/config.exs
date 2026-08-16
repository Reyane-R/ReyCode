import Config

config :os_mon, start_disksup: false

config :rey_code,
  agent_delay_ms: 45,
  provider_discovery: true,
  provider_timeout_ms: 600_000,
  allow_simulator_provider: false,
  default_provider: :unconfigured,
  squad_rework_budget: 3,
  squad_release_gate_human: true,
  openai_compatible_chunk_bytes: 8_192,
  openai_compatible_chunk_latency_ms: 50,
  start_tui: config_env() != :test

import_config "#{config_env()}.exs"
