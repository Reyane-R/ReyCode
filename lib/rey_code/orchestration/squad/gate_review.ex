defmodule ReyCode.Orchestration.Squad.GateReview do
  @moduledoc "Pending owner obligation for one squad gate."

  alias ReyCode.Orchestration.Squad.GateRecommendation

  @fields [:id, :phase, :cycle, :recommendation, :requested_at]

  defstruct id: nil, phase: nil, cycle: 0, recommendation: nil, requested_at: nil

  @type t :: %__MODULE__{
          id: String.t(),
          phase: String.t(),
          cycle: non_neg_integer(),
          recommendation: GateRecommendation.t(),
          requested_at: term()
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = review), do: review

  def from_map(review) when is_map(review) do
    review = legacy_review(review)
    review = struct!(__MODULE__, Map.take(review, @fields))
    %{review | recommendation: GateRecommendation.from_map(review.recommendation)}
  end

  defp legacy_review(%{recommendation: _recommendation} = review), do: review

  defp legacy_review(review) do
    %{
      id: Map.get(review, :id) || Map.get(review, :review_id),
      phase: Map.get(review, :phase),
      cycle: Map.get(review, :cycle, 0),
      recommendation: %{
        role_id: Map.get(review, :role_id, "squad_leader"),
        decision: Map.get(review, :decision),
        target_phase: Map.get(review, :target_phase),
        reasons: Map.get(review, :reasons, []),
        recommended_at: Map.get(review, :recorded_at)
      },
      requested_at: Map.get(review, :requested_at) || Map.get(review, :recorded_at)
    }
  end
end
