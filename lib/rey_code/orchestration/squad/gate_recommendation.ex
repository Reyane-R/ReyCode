defmodule ReyCode.Orchestration.Squad.GateRecommendation do
  @moduledoc "Advisory Squad Leader recommendation attached to a GateReview."

  @fields [:role_id, :decision, :target_phase, :reasons, :recommended_at]

  defstruct role_id: "squad_leader",
            decision: nil,
            target_phase: nil,
            reasons: [],
            recommended_at: nil

  @type t :: %__MODULE__{
          role_id: String.t(),
          decision: String.t(),
          target_phase: String.t() | nil,
          reasons: [String.t()],
          recommended_at: term()
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = recommendation), do: recommendation

  def from_map(recommendation) when is_map(recommendation) do
    struct!(__MODULE__, Map.take(recommendation, @fields))
  end
end
