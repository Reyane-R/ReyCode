import Config

config :rey_code,
  allow_simulator_provider: false,
  global_concurrency: 2,
  workspace_concurrency: 1,
  global_queue_limit: 100,
  workspace_queue_limit: 20,
  projection_checkpoint_interval: 500,
  max_replay_events: 2_000,
  max_checkpoint_bytes: 67_108_864,
  file_logging: true
