defmodule ReyCode.Orchestration.Engine.Turns do
  @moduledoc "Handles user-facing turn commands for the Engine."

  alias ReyCode.Orchestration.Engine.{Admission, Identity, Lifecycle, Persistence}
  alias ReyCode.Orchestration.Engine.VerifiedChangeResolution
  alias ReyCode.Orchestration.{EventEntries, Mode, Squad, Validation, VerifiedChangeContext}
  alias ReyCode.Orchestration.{StrategicReview, Turn}
  alias ReyCode.Provider.Catalog

  @type response :: {:reply, term(), map()}

  @doc "Validates and queues one user message for orchestration."
  @spec post_message(map(), term(), term(), term()) :: response()
  def post_message(state, session_id, raw_body, mode) do
    queue(state, %Turn{session_id: session_id, mode: mode}, raw_body)
  end

  @doc "Validates and queues one task addressed to a task participant."
  @spec delegate_task(map(), term(), term(), term()) :: response()
  def delegate_task(state, session_id, participant_id, raw_body) do
    case Map.get(state.projection.sessions, session_id) do
      %{verified_change: record} when not is_nil(record) ->
        {:reply, {:error, :verified_change_not_owner}, state}

      _ ->
        queue(
          state,
          %Turn{session_id: session_id, mode: :delegate, participant_id: participant_id},
          raw_body
        )
    end
  end

  @doc "Captures one bounded review packet before queuing the ordinary delegate lifecycle."
  @spec advise_strategy(map(), term(), term(), term(), list()) :: response()
  def advise_strategy(state, session_id, participant_id, focus, memory_entries) do
    with %{} = session <- state.projection.sessions[session_id],
         nil <- session.verified_change,
         {:ok, packet} <-
           StrategicReview.capture(state.projection, session, memory_entries, focus) do
      turn = %Turn{
        session_id: session_id,
        mode: :delegate,
        participant_id: participant_id,
        strategy_review: packet
      }

      queue(state, turn, if(focus in [nil, ""], do: "Review session strategy", else: focus))
    else
      nil -> {:reply, {:error, :session_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      %{} -> {:reply, {:error, :verified_change_not_owner}, state}
    end
  end

  @doc """
  Queues one report-only verified-change stage turn addressed to a task participant.

  Only the verified-change coordinator may post stage turns, only during the
  analyzing or releasing phases, and the verified-change boundary leaves the
  stage Invocation without tools.
  """
  @spec post_verified_stage(map(), term(), term(), term()) :: response()
  def post_verified_stage(state, session_id, participant_id, raw_body) do
    cond do
      not Map.has_key?(state.projection.sessions, session_id) ->
        {:reply, {:error, :session_not_found}, state}

      not stage_phase?(state.projection.sessions[session_id]) ->
        {:reply, {:error, :verified_change_not_owner}, state}

      true ->
        queue(
          state,
          %Turn{session_id: session_id, mode: :delegate, participant_id: participant_id},
          raw_body
        )
    end
  end

  defp stage_phase?(%{verified_change: %{phase: phase}}), do: phase in ~w(analyzing releasing)
  defp stage_phase?(_session), do: false

  @doc "Queues a new Turn linked to one failed terminal Turn."
  @spec retry(map(), term()) :: response()
  def retry(state, turn_id) do
    case Map.get(state.projection.turns, turn_id) do
      nil ->
        {:reply, {:error, :turn_not_found}, state}

      %{status: :terminal, outcome: :failed} = turn ->
        message = state.projection.messages[turn.user_message_id]

        if state.projection.sessions[turn.session_id].verified_change do
          {:reply, {:error, :verified_change_not_owner}, state}
        else
          retry = %Turn{
            session_id: turn.session_id,
            mode: turn.mode,
            participant_id: turn.participant_id,
            retry_of_turn_id: turn.id,
            strategy_review: turn.strategy_review
          }

          queue(state, retry, message.body)
        end

      _turn ->
        {:reply, {:error, :turn_not_retryable}, state}
    end
  end

  @doc "Queues one bounded correction for the next provider-round boundary."
  @spec steer(map(), term(), term()) :: response()
  def steer(state, turn_id, raw_body) do
    turn = state.projection.turns[turn_id]

    with %{} <- turn,
         true <- turn.status == :running,
         :ok <- strategy_steering(turn),
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

  @doc "Cancels and returns the newest queued FollowUp body in one Session."
  @spec dequeue_latest_follow_up(map(), term()) :: response()
  def dequeue_latest_follow_up(state, session_id) do
    session = state.projection.sessions[session_id]

    if session do
      turn =
        session.queued_turn_ids
        |> Enum.reverse()
        |> Enum.map(&state.projection.turns[&1])
        |> Enum.find(&(&1.input_kind == :follow_up and &1.status == :queued))

      dequeue_follow_up(state, turn)
    else
      {:reply, {:error, :session_not_found}, state}
    end
  end

  defp queue(state, turn, raw_body) do
    %{session_id: session_id, mode: mode, participant_id: participant_id} = turn

    cond do
      not Map.has_key?(state.projection.sessions, session_id) ->
        {:reply, {:error, :session_not_found}, state}

      not Mode.known?(mode) ->
        {:reply, {:error, :invalid_mode}, state}

      true ->
        session = state.projection.sessions[session_id]

        with :ok <- VerifiedChangeResolution.admit_work(state),
             {:ok, body} <- Validation.message(raw_body),
             :ok <- verification_admission(session),
             :ok <-
               VerifiedChangeContext.admit(
                 session.verified_change,
                 state.config.orchestration.context_budget_tokens
               ),
             :ok <- runtime_preflight(session, mode, participant_id, state),
             :ok <- Admission.admit_turn(session, state) do
          Lifecycle.queue_message(state, turn, body)
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp strategy_steering(%Turn{strategy_review: nil}), do: :ok
  defp strategy_steering(%Turn{}), do: {:error, :strategy_review_frozen}

  defp steering_size(body, max_bytes) do
    if byte_size(body) <= max_bytes, do: :ok, else: {:error, :steering_too_large}
  end

  defp verification_admission(%{verified_change: %{phase: phase}})
       when phase in ~w(ready blocked),
       do: {:error, :verified_change_terminal}

  defp verification_admission(_session), do: :ok

  defp steering_invocation(turn, state) do
    candidates =
      turn.invocation_order
      |> Enum.map(&state.projection.invocations[&1])
      |> Enum.filter(
        &(&1.status in [:queued, :running, :waiting_tool_approval, :waiting_operator])
      )

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

  defp dequeue_follow_up(state, nil), do: {:reply, {:error, :no_queued_follow_up}, state}

  defp dequeue_follow_up(state, turn) do
    body = state.projection.messages[turn.user_message_id].body

    case Lifecycle.cancel_turn(state, turn.id, "Queued FollowUp returned to Operator") do
      {:ok, next} -> {:reply, {:ok, body}, next}
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
