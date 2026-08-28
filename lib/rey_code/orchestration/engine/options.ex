defmodule ReyCode.Orchestration.Engine.Options do
  @moduledoc "Normalizes engine execution limits and default participant configuration."

  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.{Orchestration, Providers}

  @primary_participant %{
    "id" => "assistant",
    "name" => "Assistant",
    "perspective" => "general coding assistance",
    "model" => nil,
    "kind" => "primary"
  }

  @doc "Returns validated global and workspace execution limits."
  @spec execution_limits(keyword(), Orchestration.t()) :: map()
  def execution_limits(opts, policy \\ RuntimeConfig.fresh().orchestration) do
    %{
      global_concurrency: execution_limit(opts, policy, :global_concurrency, false),
      workspace_concurrency: execution_limit(opts, policy, :workspace_concurrency, false),
      global_queue_limit: execution_limit(opts, policy, :global_queue_limit, true),
      workspace_queue_limit: execution_limit(opts, policy, :workspace_queue_limit, true)
    }
  end

  @doc "Builds the session's single primary participant with the configured default provider."
  @spec default_participants(Providers.t()) :: [map()]
  def default_participants(policy \\ RuntimeConfig.fresh().providers) do
    [Map.put(@primary_participant, "provider", Atom.to_string(policy.default_provider))]
  end

  defp execution_limit(opts, policy, option, allow_zero?) do
    value = Keyword.get(opts, option, Map.fetch!(policy, option))
    minimum = if allow_zero?, do: 0, else: 1

    if value == :infinity or (is_integer(value) and value >= minimum) do
      value
    else
      raise ArgumentError, "invalid #{option}: #{inspect(value)}"
    end
  end
end
