defmodule ReyCode.Orchestration.SquadFSM do
  @moduledoc "Pure immutable state machine for the fixed leader-supervised squad workflow."

  alias ReyCode.Orchestration.Squad
  alias ReyCode.Orchestration.Squad.Phase

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            phase_index: 0,
            cycle: 0,
            rework_count: 0,
            rework_budget: 3,
            outcome: nil

  @type t :: %__MODULE__{
          session_id: String.t(),
          phase_index: non_neg_integer(),
          cycle: non_neg_integer(),
          rework_count: non_neg_integer(),
          rework_budget: pos_integer(),
          outcome: :completed | :failed | nil
        }

  @type transition :: {:continue, t()} | {:complete, t()} | {:error, atom()}

  @doc "Creates squad workflow state for a session with an optional rework budget."
  @spec new(String.t(), keyword()) :: t()
  def new(session_id, opts \\ []) do
    %__MODULE__{
      session_id: session_id,
      rework_budget: Keyword.get(opts, :rework_budget, Squad.max_rework())
    }
  end

  @doc "Returns the workflow Phase at the state's current PhaseIndex."
  @spec phase(t()) :: Phase.t() | nil
  def phase(state), do: Squad.phase(state.phase_index)

  @doc "Returns the stable label for the current Phase."
  @spec phase_label(t()) :: String.t()
  def phase_label(state), do: Squad.phase_label(state.phase_index)

  @doc "Checks whether the state has reached the completion sentinel."
  @spec complete?(t()) :: boolean()
  def complete?(state), do: state.phase_index >= Squad.complete_phase_index()

  @doc "Checks whether another rework cycle remains within budget."
  @spec rework_available?(t()) :: boolean()
  def rework_available?(state), do: state.rework_count < state.rework_budget

  @doc "Moves to the next Phase, completing when no Phases remain."
  @spec next(t()) :: {:continue, t()} | {:complete, t()}
  def next(state) do
    next_phase_index = state.phase_index + 1
    next = %{state | phase_index: next_phase_index}

    if next_phase_index >= Squad.complete_phase_index(),
      do: complete(next),
      else: {:continue, next}
  end

  @doc "Applies an authorized approve, rework, or abort gate resolution."
  @spec gate(t(), map()) :: transition()
  def gate(state, gate) do
    current = phase(state)
    resolver_id = fetch_key(gate, :resolver_id) || fetch_key(gate, :role_id)
    decision = fetch_key(gate, :decision)
    target_phase = fetch_key(gate, :target_phase)

    cond do
      not Squad.gate?(current) ->
        {:error, :not_a_gate}

      resolver_id not in ["squad_leader", "human_owner"] ->
        {:error, :leader_required}

      decision == "approve" ->
        next(state)

      decision == "abort" ->
        complete(%{state | outcome: :failed})

      decision == "rework" ->
        target = target_phase || current.rework_phase
        rework(owner_grant(state, resolver_id), target)

      true ->
        {:error, :invalid_decision}
    end
  end

  @doc "Returns to a valid target Phase while enforcing the rework budget."
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
           | phase_index: target,
             cycle: state.cycle + 1,
             rework_count: state.rework_count + 1
         }}
    end
  end

  # The Owner may authorize one rework cycle beyond an exhausted budget; the
  # Squad Leader cannot. Each owner resolution recomputes the grant from the
  # current count; the durable budget extension is recorded separately.
  defp owner_grant(%{rework_count: count, rework_budget: budget} = state, "human_owner")
       when count >= budget,
       do: %{state | rework_budget: max(budget, count) + 1}

  defp owner_grant(state, _resolver_id), do: state

  @doc "Moves the workflow to its terminal PhaseIndex while preserving a set outcome."
  @spec complete(t()) :: {:complete, t()}
  def complete(state) do
    outcome = state.outcome || :completed
    {:complete, %{state | phase_index: Squad.complete_phase_index(), outcome: outcome}}
  end

  @doc "Returns the terminal outcome, treating an unset outcome as failed."
  @spec outcome(t()) :: :completed | :failed
  def outcome(%{outcome: outcome}) when outcome in [:completed, :failed], do: outcome
  def outcome(_state), do: :failed

  defp fetch_key(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
