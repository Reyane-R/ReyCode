defmodule ReyCode.Orchestration.Engine.Options do
  @moduledoc "Normalizes engine execution limits and default participant configuration."

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
  @spec execution_limits(keyword()) :: map()
  def execution_limits(opts) do
    %{
      global_concurrency:
        execution_limit(opts, :global_concurrency, :global_concurrency, :infinity, false),
      workspace_concurrency:
        execution_limit(
          opts,
          :workspace_concurrency,
          :workspace_concurrency,
          :infinity,
          false
        ),
      global_queue_limit:
        execution_limit(opts, :global_queue_limit, :global_queue_limit, :infinity, true),
      workspace_queue_limit:
        execution_limit(
          opts,
          :workspace_queue_limit,
          :workspace_queue_limit,
          :infinity,
          true
        )
    }
  end

  @doc "Builds the fixed participant templates with the configured default provider."
  @spec default_participants() :: [map()]
  def default_participants do
    provider =
      Application.get_env(:rey_code, :default_provider, :unconfigured) |> Atom.to_string()

    Enum.map(@participant_templates, &Map.put(&1, "provider", provider))
  end

  defp execution_limit(opts, option, application_key, default, allow_zero?) do
    value = Keyword.get(opts, option, Application.get_env(:rey_code, application_key, default))
    minimum = if allow_zero?, do: 0, else: 1

    if value == :infinity or (is_integer(value) and value >= minimum) do
      value
    else
      raise ArgumentError, "invalid #{option}: #{inspect(value)}"
    end
  end
end
