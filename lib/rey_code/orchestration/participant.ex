defmodule ReyCode.Orchestration.Participant do
  @moduledoc "A configured session participant or squad role in the orchestration projection."

  alias ReyCode.Orchestration.ModelTier

  @fields [:id, :name, :perspective, :provider, :model, :model_tier, :kind]

  defstruct id: nil,
            name: nil,
            perspective: nil,
            provider: nil,
            model: nil,
            model_tier: :default,
            kind: :legacy

  @type kind :: :primary | :task | :legacy
  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          perspective: String.t() | nil,
          provider: atom() | String.t() | nil,
          model: String.t() | nil,
          model_tier: ModelTier.t(),
          kind: kind()
        }

  @doc "Converts a decoded or legacy participant map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(participant) when is_map(participant) do
    kind = kind(Map.get(participant, :kind))
    tier = model_tier(Map.get(participant, :model_tier), kind)

    participant
    |> Map.put(:kind, kind)
    |> Map.put(:model_tier, tier)
    |> then(&struct!(__MODULE__, Map.take(&1, @fields)))
  end

  defp model_tier(nil, kind), do: ModelTier.default(kind)

  defp model_tier(value, kind) do
    case ModelTier.normalize(value) do
      {:ok, tier} -> tier
      {:error, :invalid_model_tier} -> ModelTier.default(kind)
    end
  end

  defp kind(:primary), do: :primary
  defp kind("primary"), do: :primary
  defp kind(:task), do: :task
  defp kind("task"), do: :task
  defp kind(_kind), do: :legacy
end
