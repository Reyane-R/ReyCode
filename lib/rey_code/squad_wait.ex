defmodule ReyCode.SquadWait do
  @moduledoc """
  Notification-driven wait for one squad turn's terminal outcome.

  Subscribes to Engine projection broadcasts and consumes only snapshots
  whose durable `sequence` advances past the subscribed baseline, so stale
  or duplicate notifications queued around registration can never regress
  the observed turn. Waiting is bounded by an optional monotonic
  `timeout_ms` deadline; without one, the configured provider execution
  policy bounds each invocation and terminal outcomes arrive on their own.
  Every durable terminal outcome — including `:cancelled` — returns
  promptly, and a deadline that expires is reported as `:timed_out`, a
  result distinct from any turn outcome.
  """

  alias ReyCode.Orchestration.Engine

  @type option ::
          {:engine, GenServer.server()}
          | {:timeout_ms, pos_integer() | nil}
          | {:on_phase, (String.t() -> term()) | nil}
          | {:on_gate_pending, (map() -> term()) | nil}

  @type result :: {:ok, map()} | {:error, :timed_out}

  @idle_check_ms 1_000

  @doc """
  Waits for the turn to reach a durable terminal outcome.

  `on_phase/1` fires once per observed squad phase transition.
  `on_gate_pending/1` fires once per pending release-gate review id; the
  callback may block (for example, prompting the owner) while Engine
  broadcasts queue up behind it.
  """
  @spec await(String.t(), [option()]) :: result
  def await(turn_id, opts \\ []) do
    engine = Keyword.get(opts, :engine, Engine)
    registry = GenServer.call(engine, :event_registry)

    baseline = Engine.subscribe(engine)
    initial_turn = Map.get(baseline.turns, turn_id)

    state = %{
      turn_id: turn_id,
      sequence: baseline.sequence,
      turn: initial_turn,
      phase: phase(initial_turn),
      announced_phase: phase(initial_turn),
      # A gate already pending at subscription time must still be surfaced.
      seen_review: nil,
      on_phase: Keyword.get(opts, :on_phase),
      on_gate_pending: Keyword.get(opts, :on_gate_pending),
      deadline: monotonic_deadline(Keyword.get(opts, :timeout_ms))
    }

    try do
      loop(state)
    after
      Registry.unregister(registry, :orchestration)
      drain_snapshots()
    end
  end

  # Announcements run before the terminal check so the last observed phase
  # or pending gate is surfaced even when it arrives with the terminal
  # snapshot itself.
  defp loop(state) do
    state = announce_gate(state)
    state = announce_phase(state)

    cond do
      match?(%{status: :terminal}, state.turn) ->
        {:ok, state.turn}

      state.deadline != :infinity and System.monotonic_time(:millisecond) >= state.deadline ->
        {:error, :timed_out}

      true ->
        step(state)
    end
  end

  defp step(state) do
    remaining =
      case state.deadline do
        :infinity -> @idle_check_ms
        deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
      end

    receive do
      {:projection_snapshot, %{sequence: sequence}} when sequence <= state.sequence ->
        # Stale baseline-era or duplicate broadcast: ignore without regressing.
        loop(state)

      {:projection_snapshot, snapshot} ->
        turn = Map.get(snapshot.turns, state.turn_id)

        loop(%{
          state
          | sequence: snapshot.sequence,
            turn: turn || state.turn,
            phase: phase(turn || state.turn)
        })
    after
      remaining ->
        case state.deadline do
          :infinity -> step(state)
          _deadline -> {:error, :timed_out}
        end
    end
  end

  defp announce_gate(%{on_gate_pending: nil} = state), do: state

  defp announce_gate(state) do
    review_id = first_review_id(state.turn)

    if is_nil(review_id) or review_id == state.seen_review do
      state
    else
      state.on_gate_pending.(state.turn)
      %{state | seen_review: review_id}
    end
  end

  defp announce_phase(%{on_phase: nil} = state), do: state

  defp announce_phase(state) do
    if state.phase != nil and state.phase != state.announced_phase do
      state.on_phase.(state.phase)
      %{state | announced_phase: state.phase}
    else
      state
    end
  end

  defp phase(%{squad: %{phase: phase}}) when is_binary(phase), do: phase
  defp phase(_turn), do: nil

  defp first_review_id(%{squad: %{pending_review: %{id: id}}}), do: id
  defp first_review_id(_turn), do: nil

  defp monotonic_deadline(nil), do: :infinity

  defp monotonic_deadline(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: System.monotonic_time(:millisecond) + timeout_ms

  defp drain_snapshots do
    receive do
      {:projection_snapshot, _snapshot} -> drain_snapshots()
    after
      0 -> :ok
    end
  end
end
