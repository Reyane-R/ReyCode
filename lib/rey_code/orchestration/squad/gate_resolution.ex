defmodule ReyCode.Orchestration.Squad.GateResolution do
  @moduledoc "Authoritative resolution of one automated or owner-reviewed squad gate."

  @fields [
    :review_id,
    :resolver_id,
    :authority,
    :decision,
    :phase,
    :cycle,
    :target_phase,
    :reasons,
    :resolved_at
  ]

  defstruct review_id: nil,
            resolver_id: nil,
            authority: nil,
            decision: nil,
            phase: nil,
            cycle: 0,
            target_phase: nil,
            reasons: [],
            resolved_at: nil

  @type t :: %__MODULE__{
          review_id: String.t() | nil,
          resolver_id: String.t(),
          authority: :owner | :squad_leader,
          decision: String.t(),
          phase: String.t(),
          cycle: non_neg_integer(),
          target_phase: String.t() | nil,
          reasons: [String.t()],
          resolved_at: term()
        }

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = resolution), do: resolution

  def from_map(resolution) when is_map(resolution) do
    resolution = legacy_resolution(resolution)
    struct!(__MODULE__, Map.take(resolution, @fields))
  end

  defp legacy_resolution(%{resolver_id: _resolver_id} = resolution), do: resolution

  defp legacy_resolution(resolution) do
    actor = Map.get(resolution, :actor)

    %{
      review_id: Map.get(resolution, :review_id),
      resolver_id: Map.get(resolution, :role_id),
      authority: if(actor == "human", do: :owner, else: :squad_leader),
      decision: Map.get(resolution, :decision),
      phase: Map.get(resolution, :phase),
      cycle: Map.get(resolution, :cycle, 0),
      target_phase: Map.get(resolution, :target_phase),
      reasons: Map.get(resolution, :reasons, []),
      resolved_at: Map.get(resolution, :recorded_at)
    }
  end
end
