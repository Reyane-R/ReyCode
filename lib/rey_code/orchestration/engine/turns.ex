defmodule ReyCode.Orchestration.Engine.Turns do
  @moduledoc "Handles user-facing turn commands for the Engine."

  alias ReyCode.Orchestration.Engine.{Admission, Identity, Lifecycle, Persistence}
  alias ReyCode.Orchestration.{EventEntries, Mode, Squad, Validation}
  alias ReyCode.Provider.Catalog

  @type response :: {:reply, term(), map()}

  @doc "Validates and queues one user message for orchestration."
  @spec post_message(map(), term(), term(), term()) :: response()
  def post_message(state, session_id, raw_body, mode) do
    queue(state, session_id, raw_body, mode, nil)
  end

  @doc "Validates and queues one task addressed to a task participant."
  @spec delegate_task(map(), term(), term(), term()) :: response()
  def delegate_task(state, session_id, participant_id, raw_body) do
    queue(state, session_id, raw_body, :delegate, participant_id)
  end

  @doc "Queues one bounded correction for the next provider-round boundary."
  @spec steer(map(), term(), term()) :: response()
  def steer(state, turn_id, raw_body) do
    turn = state.projection.turns[turn_id]

    with %{} <- turn,
         true <- turn.status == :running,
         {:ok, body} <- Validation.message(raw_body),
         :ok <- steering_size(body, state.config.orchestration.steering_max_bytes),
         {:ok, invocation} <- steering_invocation(turn, state),
         :ok <-
           steering_capacity(
             invocation,
             state.config.orchestration.steering_max_pending
           ) do
      steering_id = Identity.new_id("steering")
      entry = EventEntries.invocation_steering_requested(invocation, steering_id, body)
      next = Persistence.append_and_apply!(state, [entry])
      {:reply, :ok, next}
    else
      nil -> {:reply, {:error, :turn_not_found}, state}
      false -> {:reply, {:error, :turn_not_running}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Cancels the newest queued follow-up Turn in one Session."
  @spec cancel_latest_follow_up(map(), term()) :: response()
  def cancel_latest_follow_up(state, session_id) do
    session = state.projection.sessions[session_id]

    if session do
      turn =
        session.queued_turn_ids
        |> Enum.reverse()
        |> Enum.map(&state.projection.turns[&1])
        |> Enum.find(&(&1.input_kind == :follow_up and &1.status == :queued))

      cancel_follow_up(state, turn)
    else
      {:reply, {:error, :session_not_found}, state}
    end
  end

  defp queue(state, session_id, raw_body, mode, participant_id) do
    cond do
      not Map.has_key?(state.projection.sessions, session_id) ->
        {:reply, {:error, :session_not_found}, state}

      not Mode.known?(mode) ->
        {:reply, {:error, :invalid_mode}, state}

      true ->
        session = state.projection.sessions[session_id]

        with {:ok, body} <- Validation.message(raw_body),
             :ok <- runtime_preflight(session, mode, participant_id, state),
             :ok <- Admission.admit_turn(session, state) do
          Lifecycle.queue_message(state, session_id, body, mode, participant_id)
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp steering_size(body, max_bytes) do
    if byte_size(body) <= max_bytes, do: :ok, else: {:error, :steering_too_large}
  end

  defp steering_invocation(turn, state) do
    candidates =
      turn.invocation_order
      |> Enum.map(&state.projection.invocations[&1])
      |> Enum.filter(&(&1.status in [:queued, :running, :waiting_tool_approval]))

    case candidates do
      [invocation] -> {:ok, invocation}
      [] -> {:error, :steering_unavailable}
      _multiple -> {:error, :steering_ambiguous}
    end
  end

  defp steering_capacity(invocation, max_pending) do
    if length(invocation.pending_steering) < max_pending,
      do: :ok,
      else: {:error, :steering_queue_full}
  end

  defp cancel_follow_up(state, nil), do: {:reply, {:error, :no_queued_follow_up}, state}

  defp cancel_follow_up(state, turn) do
    case Lifecycle.cancel_turn(state, turn.id, "Queued follow-up cancelled by Operator") do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Cancels one unfinished turn."
  @spec cancel(map(), term(), term()) :: response()
  def cancel(state, turn_id, reason) do
    case Lifecycle.cancel_turn(state, turn_id, reason) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @doc "Validates and records one squad directive."
  @spec add_squad_directive(map(), term(), term()) :: response()
  def add_squad_directive(state, turn_id, raw_directive) do
    turn = state.projection.turns[turn_id]

    case Validation.squad_directive(turn, raw_directive) do
      {:ok, directive} ->
        {:reply, :ok,
         Persistence.append_and_apply!(state, [EventEntries.squad_directive(turn, directive)])}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc "Validates and records one pending squad gate decision."
  @spec resolve_gate(map(), term(), String.t() | nil, term(), term(), [term()]) :: response()
  def resolve_gate(state, turn_id, review_id, raw_decision, raw_target_phase, raw_reasons) do
    turn = state.projection.turns[turn_id]

    case Validation.gate_resolution(turn, review_id, raw_decision, raw_target_phase, raw_reasons) do
      {:ok, review, decision, target_phase, reasons} ->
        entries = [EventEntries.gate_resolved(turn, review, decision, target_phase, reasons)]
        entries = entries ++ Lifecycle.budget_extension_entries(turn, decision)
        next = state |> Persistence.append_and_apply!(entries) |> Lifecycle.advance_turn(turn.id)
        {:reply, :ok, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp runtime_preflight(session, :squad, _participant_id, state) do
    configured = session.squad_seats

    missing =
      Squad.roles()
      |> Enum.reject(fn role ->
        case configured[role.id] do
          nil -> false
          participant -> runtime_ready?(participant, state)
        end
      end)
      |> Enum.map(& &1.id)

    if missing == [], do: :ok, else: {:error, {:squad_seats_unconfigured, missing}}
  end

  defp runtime_preflight(session, :direct, nil, state) do
    session.participants
    |> Enum.find(&(&1.kind == :primary))
    |> participant_preflight(state)
  end

  defp runtime_preflight(session, :delegate, participant_id, state) do
    session.participants
    |> Enum.find(&(&1.id == participant_id and &1.kind == :task))
    |> participant_preflight(state)
  end

  # Eval bypasses batch readiness preflight so unavailable runtimes become
  # per-participant rows, but an empty task subset would open no invocations
  # and strand the session's active Turn forever.
  defp runtime_preflight(session, :eval, _participant_id, _state) do
    if Enum.any?(session.participants, &(&1.kind == :task)),
      do: :ok,
      else: {:error, :eval_participants_required}
  end

  defp runtime_preflight(session, _mode, _participant_id, state) do
    missing =
      session.participants
      |> Enum.reject(&runtime_ready?(&1, state))
      |> Enum.map(& &1.id)

    if missing == [], do: :ok, else: {:error, {:participants_unconfigured, missing}}
  end

  defp participant_preflight(nil, _state), do: {:error, :participant_not_found}

  defp participant_preflight(participant, state) do
    if runtime_ready?(participant, state),
      do: :ok,
      else: {:error, {:participants_unconfigured, [participant.id]}}
  end

  defp runtime_ready?(participant, state) do
    match?(
      {:ok, _runtime},
      Catalog.resolve(participant.provider, participant.model, state.provider_catalog)
    )
  end
end
