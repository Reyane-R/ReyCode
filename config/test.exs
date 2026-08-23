import Config

config :rey_code,
  agent_delay_ms: 0,
  allow_simulator_provider: true,
  default_provider: :simulator,
  squad_simulator: [seed: 0, delay_ms: 0, jitter_ms: 0, failure_rate: 0.0],
  squad_release_gate_human: false,
  provider_discovery: false,
  event_path:
    Path.join(
      System.tmp_dir!(),
      "rey_code_test_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}.sqlite3"
    ),
  start_tui: false
