defmodule ReyCode.Orchestration.Engine.Options do
  @moduledoc "Normalizes engine execution limits and default participant configuration."

  alias ReyCode.RuntimeConfig
  alias ReyCode.RuntimeConfig.{Orchestration, Providers}

  @participant_templates [
    %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "pragmatic implementation",
      "model" => nil
    },
    %{
      "id" => "critic",
      "name" => "Critic",
      "perspective" => "risks and failure modes",
      "model" => nil
    },
    %{
      "id" => "explorer",
      "name" => "Explorer",
      "perspective" => "alternatives and leverage",
      "model" => nil
    }
  ]

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

  @doc "Builds the fixed participant templates with the configured default provider."
  @spec default_participants(Providers.t()) :: [map()]
  def default_participants(policy \\ RuntimeConfig.fresh().providers) do
    provider = Atom.to_string(policy.default_provider)
    Enum.map(@participant_templates, &Map.put(&1, "provider", provider))
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
