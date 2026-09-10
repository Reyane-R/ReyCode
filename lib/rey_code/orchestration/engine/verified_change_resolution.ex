defmodule ReyCode.Orchestration.Engine.VerifiedChangeResolution do
  @moduledoc """
  Durable retained-patch command handlers, independent of the Engine process shell.

  Initialize `verified_change_resolution_tasks: %{}`. Route Task `{ref, result}`
  to finish/3 and matching DOWN messages to down/3 before other task handlers.
  Values are `{session_id, resolution_id, pid}`. Call recover/1 after restore,
  before admitting work. SourceTask retains a restart-visible lease until bounded
  subprocess execution drains, so a replacement Engine cannot reconcile early.
  Each worker is bounded by Patch's deadline;
  at most four resolutions execute concurrently.

  Admission is deliberately global: no coordinator, nonterminal Invocation/Turn,
  or owner command may overlap resolution. All new Engine-managed work uses
  admit_work/1 because configured tool roots can cross Session workspaces.
  Indeterminate decisions keep the barrier until explicit reconciliation settles
  them. Independent ProcessHub/EvalHub jobs and external writers are outside this
  admission boundary; they are not made transactional by an Engine barrier.
  """

  alias ReyCode.Orchestration.Engine.{Identity, Persistence, SourceTask}
  alias ReyCode.Orchestration.{Projection, Session}
  alias ReyCode.Orchestration.VerifiedChangeResolution, as: Resolution
  alias ReyCode.VerifiedChange.Patch

  @max_tasks_count 4

  @spec resolve(map(), term(), term(), term(), term()) :: {:reply, term(), map()}
  def resolve(state, session_id, change_id, patch_hash, decision) do
    record = %Resolution{
      id: Identity.new_id("resolution"),
      change_id: change_id,
      patch_hash: patch_hash,
      decision: decision,
      status: :requested,
      error: nil
    }

    with {:ok, session} <- fetch_session(state, session_id),
         :ok <- validate_request(session, record),
         :ok <- admit(state, session) do
      state = persist(state, session_id, record)
      state = dispatch(state, session, record, :execute)
      {:reply, {:ok, record.id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec reconcile(map(), term(), term(), term()) :: {:reply, term(), map()}
  def reconcile(state, session_id, change_id, patch_hash) do
    with {:ok, session} <- fetch_session(state, session_id),
         %Resolution{status: :indeterminate, change_id: ^change_id, patch_hash: ^patch_hash} =
           record <- session.verified_change_resolution,
         false <- running?(state, session_id),
         :ok <- idle(state),
         true <- map_size(state.verified_change_resolution_tasks) < @max_tasks_count do
      {:reply, {:ok, record.id}, dispatch(state, session, record, :reconcile)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :resolution_not_reconcilable}, state}
    end
  end

  @doc "Consumes only registered task results; unknown/stale references are harmless."
  @spec finish(map(), reference(), Patch.result()) :: {:noreply, map()}
  def finish(state, ref, {status, error}) do
    case Map.pop(state.verified_change_resolution_tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {{session_id, resolution_id, _pid}, tasks} ->
        Process.demonitor(ref, [:flush])
        record = state.projection.sessions[session_id].verified_change_resolution
        ^resolution_id = record.id
        next = %{record | status: status, error: error}
        {:ok, ^next} = next |> Resolution.to_wire() |> Resolution.from_wire()
        :ok = Resolution.transition(record, next)
        {:noreply, persist(%{state | verified_change_resolution_tasks: tasks}, session_id, next)}
    end
  end

  @spec down(map(), reference(), term()) :: {:noreply, map()}
  def down(state, ref, _reason),
    do: finish(state, ref, {:indeterminate, "resolution_worker_interrupted"})

  @doc "Never replays filesystem mutation on restart. Journal every unfinished intent as uncertain."
  @spec recover(map()) :: map()
  def recover(state) do
    Enum.reduce(state.projection.sessions, state, fn {session_id, session}, acc ->
      case session.verified_change_resolution do
        %Resolution{status: :requested} = record ->
          persist(acc, session_id, %{
            record
            | status: :indeterminate,
              error: "resolution_interrupted_by_restart"
          })

        _ ->
          acc
      end
    end)
  end

  @doc "Projection-derived barrier for canonical source paths and their descendants."
  @spec locked_workspace?(Projection.t(), String.t()) :: boolean()
  def locked_workspace?(projection, path) do
    Enum.any?(projection.sessions, fn {_id, session} ->
      case {session.verified_change, session.verified_change_resolution} do
        {%{source_workspace: source}, %Resolution{status: status}}
        when status in [:requested, :indeterminate] ->
          overlaps?(source, path)

        _ ->
          false
      end
    end)
  end

  @doc "Conservative global admission barrier; configured tool roots can cross Workspaces."
  @spec admit_work(map()) :: :ok | {:error, :verified_change_source_locked}
  def admit_work(state) do
    if locked?(state.projection), do: {:error, :verified_change_source_locked}, else: :ok
  end

  @spec locked?(Projection.t()) :: boolean()
  def locked?(projection) do
    Enum.any?(projection.sessions, fn {_id, session} ->
      match?(
        %Resolution{status: status} when status in [:requested, :indeterminate],
        session.verified_change_resolution
      )
    end)
  end

  @doc "Rejects live, queued, approval-paused, detached, coordinator and draining owner work globally."
  @spec idle(map()) :: :ok | {:error, :verified_change_busy}
  def idle(state) do
    busy? =
      SourceTask.busy?(state) or
        map_size(Map.get(state, :owner_command_tasks, %{})) > 0 or
        map_size(Map.get(state, :verified_changes, %{})) > 0 or
        map_size(Map.get(state, :active_executions, %{})) > 0 or
        Enum.any?(state.projection.sessions, fn {_id, session} ->
          match?(%{phase: phase} when phase not in ["ready", "blocked"], session.verified_change)
        end) or
        Enum.any?(state.projection.turns, fn {_id, turn} -> turn.status != :terminal end) or
        Enum.any?(state.projection.invocations, fn {_id, invocation} ->
          invocation.status not in [:completed, :failed, :cancelled]
        end)

    if busy?, do: {:error, :verified_change_busy}, else: :ok
  end

  defp fetch_session(state, session_id) do
    case Map.get(state.projection.sessions, session_id) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :session_not_found}
    end
  end

  defp validate_request(session, record) do
    cond do
      record.decision not in [:apply, :discard] ->
        {:error, :invalid_resolution_decision}

      not Resolution.bound?(record, session.verified_change) ->
        {:error, :stale_or_ineligible_verified_change}

      session.verified_change_resolution != nil ->
        {:error, :verified_change_already_resolved}

      true ->
        :ok
    end
  end

  defp admit(state, session) do
    cond do
      map_size(state.verified_change_resolution_tasks) >= @max_tasks_count ->
        {:error, :resolution_capacity_exceeded}

      locked?(state.projection) ->
        {:error, :verified_change_source_locked}

      session.active_turn_id != nil or session.queued_turn_ids != [] ->
        {:error, :verified_change_busy}

      true ->
        idle(state)
    end
  end

  defp running?(state, session_id),
    do:
      Enum.any?(state.verified_change_resolution_tasks, fn {_ref, {id, _resolution_id, _pid}} ->
        id == session_id
      end)

  defp overlaps?(left, right),
    do:
      left == right or String.starts_with?(left, String.trim_trailing(right, "/") <> "/") or
        String.starts_with?(right, String.trim_trailing(left, "/") <> "/")

  defp dispatch(state, session, record, operation) do
    case start_task(state, session.verified_change, record.decision, operation) do
      {:ok, task} ->
        tasks =
          Map.put(
            state.verified_change_resolution_tasks,
            task.ref,
            {session.id, record.id, task.pid}
          )

        %{state | verified_change_resolution_tasks: tasks}

      {:error, _reason} ->
        persist(state, session.id, %{
          record
          | status: :indeterminate,
            error: "resolution_dispatch_failed"
        })
    end
  end

  defp start_task(state, change, decision, operation) do
    SourceTask.start(state, fn owner ->
      case operation do
        :execute -> Patch.execute(change, decision, owner)
        :reconcile -> Patch.reconcile(change, decision)
      end
    end)
  end

  defp persist(state, session_id, record) do
    entry =
      {:verified_change_resolution_recorded,
       %{"room_id" => session_id, "record" => Resolution.to_wire(record)},
       [aggregate_type: :room, aggregate_id: session_id, room_id: session_id]}

    Persistence.append_and_apply!(state, [entry])
  end
end
