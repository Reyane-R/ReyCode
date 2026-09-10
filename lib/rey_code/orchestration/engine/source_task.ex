defmodule ReyCode.Orchestration.Engine.SourceTask do
  @moduledoc """
  Supervised, Engine-owned source execution with a restart-visible draining lease.

  Register before executing, and never execute for an already-dead Engine. Engine
  death does not brutally kill a task inside a Git/Exile call: its bounded operation
  drains, including subprocess cleanup, before its registry lease disappears.
  Patch additionally checks its Engine immediately before source mutation. The
  replacement Engine rejects resolution/reconciliation while any lease remains.
  This avoids equating BEAM worker death with OS subprocess termination.

  Invocation/check operations validate their scope and caller in the Engine, then
  check caller liveness again when execution begins. Killing an InvocationWorker
  or verification coordinator stops continuation, not an already-running lease.
  Startup handshakes before admission returns. At most 64 leases or pending
  operation completions are admitted; caller timeouts never kill draining work.

  The duplicate EventRegistry survives Engine restarts and scopes leases to the
  same orchestration instance. Callers supply bounded operations only (Patch's
  60-second deadline or Bash's configured timeout plus cleanup). Independently
  authorized background processes and external writers are not sandboxed here.
  """

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Orchestration.Engine.VerifiedChangeResolution
  alias ReyCode.VerifiedChange.Interactive

  @max_tasks_count 64
  @registration_timeout_ms 5_000

  @doc "Runs an internal bounded external operation without linking its lifetime to the caller."
  @spec run(GenServer.server(), tuple(), (-> term()), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def run(engine, scope_id, operation, timeout_ms) do
    case GenServer.whereis(engine) do
      nil -> {:error, :engine_stopped}
      owner -> await_operation(owner, scope_id, operation, timeout_ms)
    end
  end

  defp await_operation(owner, scope_id, operation, timeout_ms) do
    monitor = Process.monitor(owner)
    request_ref = make_ref()

    try do
      case Engine.start_source_operation(scope_id, operation, request_ref, owner) do
        :ok ->
          receive do
            {:source_operation_result, ^request_ref, result} -> result
            {:DOWN, ^monitor, :process, ^owner, _reason} -> {:error, :engine_stopped}
          after
            timeout_ms -> {:error, :source_operation_timeout}
          end

        {:error, _} = error ->
          error
      end
    catch
      :exit, _ -> {:error, :source_operation_unavailable}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc "Registers a restart-visible lease before returning; no operation runs before registration."
  @spec start(map(), (pid() -> term()), tuple() | nil) :: {:ok, Task.t()} | {:error, atom()}
  def start(state, operation, scope \\ nil) do
    if length(Registry.lookup(state.event_registry, __MODULE__)) >= @max_tasks_count do
      {:error, :source_operation_capacity}
    else
      start_registered(state, operation, scope)
    end
  end

  defp start_registered(state, operation, scope) do
    owner = self()
    registry = state.event_registry
    token = make_ref()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        {:ok, _} = Registry.register(registry, __MODULE__, scope)
        send(owner, {:source_task_registered, token})

        receive do
          {:execute, ^token} ->
            if Process.alive?(owner),
              do: operation.(owner),
              else: {:indeterminate, "engine_stopped"}
        after
          @registration_timeout_ms -> {:indeterminate, "source_registration_timeout"}
        end
      end)

    task_ref = task.ref

    receive do
      {:source_task_registered, ^token} ->
        send(task.pid, {:execute, token})
        {:ok, task}

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        {:error, :dispatch_failed}
    after
      @registration_timeout_ms ->
        Task.shutdown(task, :brutal_kill)
        {:error, :dispatch_failed}
    end
  rescue
    _ -> {:error, :dispatch_failed}
  catch
    :exit, _ -> {:error, :dispatch_failed}
  end

  @doc "Includes draining tasks belonging to a previous Engine process."
  @spec busy?(map()) :: boolean()
  def busy?(state), do: Registry.lookup(state.event_registry, __MODULE__) != []

  @doc "Tracks check and provider-tool drain independently of coordinator existence."
  @spec verification_busy?(map(), String.t()) :: boolean()
  def verification_busy?(state, session_id) do
    Enum.any?(Registry.lookup(state.event_registry, __MODULE__), fn
      {_pid, {:verification, ^session_id}} -> true
      _ -> false
    end)
  end

  @doc "Conservatively keeps all interactive slots closed while a stopped owner still drains."
  @spec admit_verification(map()) :: :ok | {:error, :verified_change_stopping}
  def admit_verification(state) do
    draining? =
      Enum.any?(Registry.lookup(state.event_registry, __MODULE__), fn
        {_pid, {:verification, session_id}} ->
          not Map.has_key?(state.verified_changes, session_id) or
            state.projection.sessions[session_id].verified_change.phase in ["ready", "blocked"]

        _ ->
          false
      end)

    if draining?, do: {:error, :verified_change_stopping}, else: :ok
  end

  @doc false
  def admit(state, scope_id, operation, request_ref, caller)
      when is_function(operation, 0) and is_reference(request_ref) do
    owned_operation = fn _owner ->
      if Process.alive?(caller),
        do: {:ok, operation.()},
        else: {:error, :source_caller_stopped}
    end

    with :ok <- VerifiedChangeResolution.admit_work(state),
         true <- map_size(state.source_operation_tasks) < @max_tasks_count,
         {:ok, scope} <- authorized_scope(state, scope_id, caller),
         {:ok, task} <- start(state, owned_operation, scope) do
      tasks = Map.put(state.source_operation_tasks, task.ref, {caller, request_ref})
      {:reply, :ok, %{state | source_operation_tasks: tasks}}
    else
      false -> {:reply, {:error, :source_operation_capacity}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def admit(state, _scope_id, _operation, _request_ref, _caller),
    do: {:reply, {:error, :invalid_source_operation}, state}

  @doc false
  def finish(state, ref, result) do
    {{caller, request_ref}, tasks} = Map.pop(state.source_operation_tasks, ref)
    Process.demonitor(ref, [:flush])
    send(caller, {:source_operation_result, request_ref, result})
    {:noreply, %{state | source_operation_tasks: tasks}}
  end

  @doc false
  def down(state, ref), do: finish(state, ref, {:error, :source_operation_interrupted})

  defp authorized_scope(state, {:invocation, invocation_id}, caller) do
    with %{status: :running, session_id: session_id} <-
           Map.get(state.projection.invocations, invocation_id),
         [{^caller, _}] <- Registry.lookup(state.agent_registry, invocation_id) do
      if state.projection.sessions[session_id].verified_change,
        do: {:ok, {:verification, session_id}},
        else: {:ok, {:invocation, invocation_id}}
    else
      _ -> {:error, :source_operation_not_owner}
    end
  end

  defp authorized_scope(state, {:verification, session_id}, caller) do
    with %{verified_change: %{phase: phase}} when phase not in ["ready", "blocked"] <-
           Map.get(state.projection.sessions, session_id),
         true <- Interactive.authorized?(state, session_id, caller) do
      {:ok, {:verification, session_id}}
    else
      _ -> {:error, :source_operation_not_owner}
    end
  end

  defp authorized_scope(_state, _scope_id, _caller), do: {:error, :source_operation_not_owner}
end
