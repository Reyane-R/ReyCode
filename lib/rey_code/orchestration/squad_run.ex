defmodule ReyCode.Orchestration.SquadRun do
  @moduledoc "Typed leader-supervised workflow state attached to a squad Turn."

  alias ReyCode.Orchestration.Squad.{GateResolution, GateReview}

  @fields [
    :room_id,
    :workflow_version,
    :release_authority,
    :phase_index,
    :phase,
    :cycle,
    :rework_count,
    :rework_budget,
    :role_ids,
    :resolutions,
    :latest_resolution,
    :promotions,
    :artifacts,
    :blockers,
    :retries,
    :directives,
    :reviews,
    :pending_review
  ]

  defstruct room_id: nil,
            workflow_version: nil,
            release_authority: :owner,
            phase_index: 0,
            phase: nil,
            cycle: 0,
            rework_count: 0,
            rework_budget: 0,
            role_ids: [],
            resolutions: [],
            latest_resolution: nil,
            promotions: %{},
            artifacts: [],
            blockers: [],
            retries: [],
            directives: [],
            reviews: [],
            pending_review: nil

  @type release_authority :: :owner | :squad_leader
  @type t :: %__MODULE__{
          room_id: String.t(),
          workflow_version: String.t(),
          release_authority: release_authority(),
          phase_index: non_neg_integer(),
          phase: String.t(),
          cycle: non_neg_integer(),
          rework_count: non_neg_integer(),
          rework_budget: pos_integer(),
          role_ids: [String.t()],
          resolutions: [GateResolution.t()],
          latest_resolution: GateResolution.t() | nil,
          promotions: map(),
          artifacts: [map()],
          blockers: [String.t()],
          retries: [map()],
          directives: [map()],
          reviews: [GateReview.t()],
          pending_review: GateReview.t() | nil
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = run), do: run

  def from_map(run) when is_map(run) do
    run = normalize_legacy(run)
    run = struct!(__MODULE__, Map.take(run, @fields))

    %{
      run
      | resolutions: Enum.map(run.resolutions || [], &GateResolution.from_map/1),
        latest_resolution: optional(run.latest_resolution, &GateResolution.from_map/1),
        reviews: Enum.map(run.reviews || [], &GateReview.from_map/1),
        pending_review: optional(run.pending_review, &GateReview.from_map/1)
    }
  end

  defp normalize_legacy(run) do
    run
    |> Map.put_new(:phase_index, Map.get(run, :stage, 0))
    |> Map.put_new(:role_ids, Map.get(run, :seats, []))
    |> Map.put_new(:resolutions, Map.get(run, :decisions, []))
    |> Map.put_new(:latest_resolution, Map.get(run, :latest_gate))
    |> Map.put_new(:reviews, Map.get(run, :gate_reviews, []))
    |> Map.update(:release_authority, :owner, &normalize_authority/1)
  end

  defp normalize_authority("human"), do: :owner
  defp normalize_authority("leader"), do: :squad_leader
  defp normalize_authority(:owner), do: :owner
  defp normalize_authority(:squad_leader), do: :squad_leader

  defp optional(nil, _convert), do: nil
  defp optional(value, convert), do: convert.(value)
end
