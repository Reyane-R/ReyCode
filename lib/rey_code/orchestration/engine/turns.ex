defmodule ReyCode.Orchestration.Engine.Turns do
  @moduledoc "Handles user-facing turn commands for the Engine."

  alias ReyCode.Orchestration.Engine.{Admission, Lifecycle, Persistence}
  alias ReyCode.Orchestration.{EventEntries, Mode, Squad, Validation}
  alias ReyCode.Provider.Catalog

  @type response :: {:reply, term(), map()}

  @doc "Validates and queues one user message for orchestration."
  @spec post_message(map(), term(), term(), term()) :: response()
  def post_message(state, room_id, raw_body, mode) do
    queue(state, room_id, raw_body, mode, nil)
  end

  @doc "Validates and queues one task addressed to a task participant."
  @spec delegate_task(map(), term(), term(), term()) :: response()
  def delegate_task(state, room_id, participant_id, raw_body) do
    queue(state, room_id, raw_body, :delegate, participant_id)
  end

  defp queue(state, room_id, raw_body, mode, participant_id) do
    cond do
      not Map.has_key?(state.projection.rooms, room_id) ->
        {:reply, {:error, :room_not_found}, state}

      not Mode.known?(mode) ->
        {:reply, {:error, :invalid_mode}, state}

      true ->
        room = state.projection.rooms[room_id]

        with {:ok, body} <- Validation.message(raw_body),
             :ok <- runtime_preflight(room, mode, participant_id, state),
             :ok <- Admission.admit_turn(room, state) do
          Lifecycle.queue_message(state, room_id, body, mode, participant_id)
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
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

  defp runtime_preflight(room, :squad, _participant_id, state) do
    configured = room.squad_seats

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

  defp runtime_preflight(room, :direct, nil, state) do
    room.participants
    |> Enum.find(&(&1.kind == :primary))
    |> participant_preflight(state)
  end

  defp runtime_preflight(room, :delegate, participant_id, state) do
    room.participants
    |> Enum.find(&(&1.id == participant_id and &1.kind == :task))
    |> participant_preflight(state)
  end

  # Eval bypasses batch readiness preflight so unavailable runtimes become
  # per-participant rows, but an empty task subset would open no invocations
  # and strand the room's active Turn forever.
  defp runtime_preflight(room, :eval, _participant_id, _state) do
    if Enum.any?(room.participants, &(&1.kind == :task)),
      do: :ok,
      else: {:error, :eval_participants_required}
  end

  defp runtime_preflight(room, _mode, _participant_id, state) do
    missing =
      room.participants
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
