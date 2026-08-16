defmodule ReyCode.RuntimeConfig do
  @moduledoc false

  @positive_limits ~w(
    global_concurrency workspace_concurrency provider_timeout_ms
    opencode_text_chunk_bytes opencode_cpu_seconds opencode_open_files
    projection_checkpoint_interval max_replay_events max_checkpoint_bytes
  )a
  @nonnegative_limits ~w(
    global_queue_limit workspace_queue_limit opencode_text_chunk_latency_ms
  )a

  def validate! do
    Enum.each(@positive_limits, &validate_limit!(&1, 1))
    Enum.each(@nonnegative_limits, &validate_limit!(&1, 0))

    case Application.get_env(:rey_code, :workspace_roots, []) do
      roots when is_list(roots) -> :ok
      value -> raise ArgumentError, "workspace_roots must be a list, got: #{inspect(value)}"
    end

    :ok
  end

  defp validate_limit!(key, minimum) do
    case Application.get_env(:rey_code, key, :infinity) do
      :infinity -> :ok
      value when is_integer(value) and value >= minimum -> :ok
      value -> raise ArgumentError, "invalid #{key}: #{inspect(value)}"
    end
  end
end
