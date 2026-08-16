defmodule ReyCode.Orchestration.Engine.Admission do
  @moduledoc "Pure admission-control policy for turns and provider worker scheduling."

  @doc "Appends an invocation to the execution queue when it is not already enqueued."
  @spec enqueue(map(), String.t()) :: map()
  def enqueue(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil or invocation.status in [:completed, :failed, :cancelled] ->
        state

      Map.has_key?(state.active_executions, invocation_id) ->
        state

      MapSet.member?(state.queued_execution_ids, invocation_id) ->
        state

      true ->
        %{
          state
          | execution_queue: state.execution_queue ++ [invocation_id],
            queued_execution_ids: MapSet.put(state.queued_execution_ids, invocation_id)
        }
    end
  end

  @doc "Finds the next queue entry that fits within global and workspace limits."
  @spec next_eligible(map()) :: {String.t(), non_neg_integer()} | nil
  def next_eligible(state) do
    if limit_available?(map_size(state.active_executions), state.limits.global_concurrency) do
      state.execution_queue
      |> Enum.with_index()
      |> Enum.find(&workspace_slot_available?(state, &1))
    end
  end

  @doc "Checks whether a turn can start now or wait within configured queue limits."
  @spec admit_turn(map(), map()) :: :ok | {:error, :global_queue_full | :workspace_queue_full}
  def admit_turn(room, state) do
    global_waiting = length(state.execution_queue) + queued_turn_count(state.projection)
    workspace_waiting = workspace_waiting_count(room.workspace, state)

    workspace_active =
      Enum.count(state.active_executions, fn {_id, workspace} ->
        workspace == Path.expand(room.workspace)
      end)

    can_start? =
      room.active_turn_id == nil and
        limit_available?(map_size(state.active_executions), state.limits.global_concurrency) and
        limit_available?(workspace_active, state.limits.workspace_concurrency)

    cond do
      can_start? ->
        :ok

      not limit_available?(global_waiting, state.limits.global_queue_limit) ->
        {:error, :global_queue_full}

      not limit_available?(workspace_waiting, state.limits.workspace_queue_limit) ->
        {:error, :workspace_queue_full}

      true ->
        :ok
    end
  end

  @doc "Removes a selected invocation from the execution queue."
  @spec dequeue(map(), {String.t(), non_neg_integer()}) :: map()
  def dequeue(state, {invocation_id, index}) do
    {_removed, queue} = List.pop_at(state.execution_queue, index)

    %{
      state
      | execution_queue: queue,
        queued_execution_ids: MapSet.delete(state.queued_execution_ids, invocation_id)
    }
  end

  @doc "Drops cancelled invocations from queued and active execution tracking."
  @spec drop_executions(map(), [String.t()]) :: map()
  def drop_executions(state, invocation_ids) do
    dropped = MapSet.new(invocation_ids)

    %{
      state
      | execution_queue: Enum.reject(state.execution_queue, &MapSet.member?(dropped, &1)),
        queued_execution_ids: MapSet.difference(state.queued_execution_ids, dropped),
        active_executions: Map.drop(state.active_executions, invocation_ids)
    }
  end

  @doc "Checks whether the invocation's workspace still has capacity."
  @spec workspace_slot_available?(map(), {String.t(), non_neg_integer()}) :: boolean()
  def workspace_slot_available?(state, {invocation_id, _index}) do
    workspace = workspace(state, invocation_id)
    active = Enum.count(state.active_executions, fn {_id, value} -> value == workspace end)
    limit_available?(active, state.limits.workspace_concurrency)
  end

  @doc "Resolves the expanded workspace path an invocation runs in."
  @spec workspace(map(), String.t()) :: String.t()
  def workspace(state, invocation_id) do
    invocation = state.projection.invocations[invocation_id]
    room = invocation && state.projection.rooms[invocation.room_id]
    if room, do: Path.expand(room.workspace), else: "unknown"
  end

  @doc "Checks whether current usage is within the configured limit."
  @spec limit_available?(non_neg_integer(), pos_integer() | :infinity) :: boolean()
  def limit_available?(_current, :infinity), do: true
  def limit_available?(current, limit), do: current < limit

  defp queued_turn_count(projection) do
    Enum.count(projection.turns, fn {_id, turn} -> turn.status == :queued end)
  end

  defp workspace_waiting_count(workspace, state) do
    workspace = Path.expand(workspace)

    queued_turns =
      Enum.count(state.projection.turns, fn {_id, turn} ->
        room = state.projection.rooms[turn.room_id]
        (turn.status == :queued and room) && Path.expand(room.workspace) == workspace
      end)

    queued_executions =
      Enum.count(state.execution_queue, &(workspace(state, &1) == workspace))

    queued_turns + queued_executions
  end
end
