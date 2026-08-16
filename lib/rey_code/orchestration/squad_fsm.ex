defmodule ReyCode.Orchestration.SquadFSM do
  @moduledoc "Pure immutable state machine for the fixed leader-supervised squad workflow."

  alias ReyCode.Orchestration.Squad

  @enforce_keys [:room_id]
  defstruct room_id: nil,
            phase: 0,
            cycle: 0,
            rework_count: 0,
            rework_budget: 3,
            outcome: nil

  @type t :: %__MODULE__{
          room_id: String.t(),
          phase: non_neg_integer(),
          cycle: non_neg_integer(),
          rework_count: non_neg_integer(),
          rework_budget: pos_integer(),
          outcome: :completed | :failed | nil
        }

  @type transition ::
          {:continue, t()}
          | {:complete, t()}
          | {:error, atom()}

  @doc "Creates squad workflow state for a room with an optional rework budget."
  @spec new(String.t(), keyword()) :: t()
  def new(room_id, opts \\ []) do
    %__MODULE__{
      room_id: room_id,
      rework_budget: Keyword.get(opts, :rework_budget, Squad.max_rework())
    }
  end

  @doc "Returns the workflow phase at the state's current position."
  @spec phase(t()) :: map() | nil
  def phase(state), do: Squad.phase(state.phase)

  @doc "Returns the stable label for the current workflow stage."
  @spec stage_label(t()) :: String.t()
  def stage_label(state), do: Squad.stage_label(state.phase)

  @doc "Checks whether the state has reached the completion sentinel."
  @spec complete?(t()) :: boolean()
  def complete?(state), do: state.phase >= Squad.complete_stage()

  @doc "Checks whether another rework cycle remains within budget."
  @spec rework_available?(t()) :: boolean()
  def rework_available?(state), do: state.rework_count < state.rework_budget

  @doc "Moves to the next phase, completing when no phases remain."
  @spec next(t()) :: {:continue, t()} | {:complete, t()}
  def next(state) do
    next_phase = state.phase + 1
    next = %{state | phase: next_phase}

    if next_phase >= Squad.complete_stage(), do: complete(next), else: {:continue, next}
  end

  @doc "Applies an authorized approve, rework, or abort gate decision."
  @spec gate(t(), map()) :: transition()
  def gate(state, gate) do
    current = phase(state)
    role_id = fetch_key(gate, :role_id)
    decision = fetch_key(gate, :decision)
    target_phase = fetch_key(gate, :target_phase)

    cond do
      not Squad.gate?(current) ->
        {:error, :not_a_gate}

      role_id not in ["squad_leader", "human_owner"] ->
        {:error, :leader_required}

      decision == "approve" ->
        next(state)

      decision == "abort" ->
        complete(%{state | outcome: :failed})

      decision == "rework" ->
        target = target_phase || current.rework_to
        rework(state, target)

      true ->
        {:error, :invalid_decision}
    end
  end

  @doc "Returns to a valid target phase while enforcing the rework budget."
  @spec rework(t(), String.t() | nil) :: transition()
  def rework(state, target_phase) do
    target = target_phase && Squad.phase_index(target_phase)

    cond do
      target == nil ->
        {:error, :invalid_rework_target}

      not rework_available?(state) ->
        complete(%{state | outcome: :failed})

      true ->
        {:continue,
         %{
           state
           | phase: target,
             cycle: state.cycle + 1,
             rework_count: state.rework_count + 1
         }}
    end
  end

  @doc "Moves the workflow to its terminal stage while preserving a set outcome."
  @spec complete(t()) :: {:complete, t()}
  def complete(state) do
    outcome = state.outcome || :completed
    {:complete, %{state | phase: Squad.complete_stage(), outcome: outcome}}
  end

  @doc "Returns the terminal outcome, treating an unset outcome as failed."
  @spec outcome(t()) :: :completed | :failed
  def outcome(%{outcome: outcome}) when outcome in [:completed, :failed], do: outcome
  def outcome(_state), do: :failed

  defp fetch_key(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
