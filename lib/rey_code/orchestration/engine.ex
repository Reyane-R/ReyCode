defmodule ReyCode.Orchestration.Engine do
  @moduledoc "Owns durable room state and schedules provider invocations."

  use GenServer

  alias ReyCode.EventStore

  alias ReyCode.Orchestration.Projector

  alias ReyCode.Orchestration.Engine.{
    Admission,
    Lifecycle,
    Loop,
    Options,
    OwnerCommand,
    Persistence,
    Rooms,
    Turns,
    WorkerExit
  }

  alias ReyCode.Provider.Catalog
  alias ReyCode.RuntimeConfig

  @doc "Starts an orchestration engine with the configured runtime dependencies and limits."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the engine's current orchestration projection."
  @spec snapshot(GenServer.server()) :: Projector.state()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  Subscribes the caller to projection broadcasts and returns the current projection.

  Registration and snapshot are performed together so the observable state is
  guaranteed to be a consistent baseline: registering first means every later
  broadcast is received, and the returned snapshot represents the state at
  registration time.
  """
  def subscribe(server \\ __MODULE__) do
    event_registry = GenServer.call(server, :event_registry)

    case Registry.register(event_registry, :orchestration, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end

    snapshot(server)
  end

  @doc "Creates a room rooted at a workspace and returns its ID."
  @spec create_room(term(), term(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def create_room(title, workspace \\ File.cwd!(), server \\ __MODULE__) do
    GenServer.call(server, {:create_room, title, workspace})
  end

  @doc "Creates a fresh durable session titled from its first input."
  @spec create_session(term(), term(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def create_session(source_room_id, title, server \\ __MODULE__) do
    GenServer.call(server, {:create_session, source_room_id, title})
  end

  @doc "Runs one owner-typed shell command and records its transcript message."
  @spec run_owner_command(term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def run_owner_command(room_id, command, server \\ __MODULE__) do
    GenServer.call(server, {:run_owner_command, room_id, command})
  end

  @doc "Adds one durable task participant to a room."
  @spec add_task_participant(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, atom()}
  def add_task_participant(room_id, name, responsibility, server \\ __MODULE__) do
    GenServer.call(server, {:add_task_participant, room_id, name, responsibility})
  end

  @doc "Queues a user message for orchestration in the requested mode."
  @spec post_message(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def post_message(room_id, body, mode, server \\ __MODULE__) do
    GenServer.call(server, {:post_message, room_id, body, mode})
  end

  @doc "Queues one explicit task for one task participant."
  @spec delegate_task(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def delegate_task(room_id, participant_id, task, server \\ __MODULE__) do
    GenServer.call(server, {:delegate_task, room_id, participant_id, task})
  end

  @doc "Cancels an unfinished turn and its outstanding provider invocations."
  @spec cancel_turn(term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def cancel_turn(turn_id, reason \\ "Cancelled by user", server \\ __MODULE__) do
    GenServer.call(server, {:cancel_turn, turn_id, reason}, :infinity)
  end

  @doc "Assigns a provider and model to selected room participants."
  @spec configure_participants(term(), term(), term(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def configure_participants(room_id, participant_ids, provider, model, server \\ __MODULE__) do
    GenServer.call(server, {:configure_participants, room_id, participant_ids, provider, model})
  end

  @doc "Assigns a provider and model to selected squad roles in a room."
  @spec configure_squad_roles(term(), term(), term(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def configure_squad_roles(room_id, role_ids, provider, model, server \\ __MODULE__) do
    GenServer.call(server, {:configure_squad_roles, room_id, role_ids, provider, model})
  end

  @doc "Adds operator guidance to a running squad turn."
  @spec add_squad_directive(term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def add_squad_directive(turn_id, directive, server \\ __MODULE__) do
    GenServer.call(server, {:add_squad_directive, turn_id, directive})
  end

  @doc """
  Records the human decision for a pending squad gate review.

  The `review_id` must match the review that was displayed when the caller
  opened the modal, so a stale view can never resolve a newer gate.
  """
  @spec resolve_gate(term(), String.t() | nil, term(), term(), [term()], GenServer.server()) ::
          :ok | {:error, atom()}
  def resolve_gate(
        turn_id,
        review_id,
        decision,
        target_phase \\ nil,
        reasons \\ [],
        server \\ __MODULE__
      ) do
    GenServer.call(server, {:resolve_gate, turn_id, review_id, decision, target_phase, reasons})
  end

  @doc """
  Records the owner's decision for one durable tool run.

  Decisions are addressed by ToolRun ID so a stale or duplicated review can
  never resolve a different request than the one displayed.
  """
  @spec resolve_tool_run(term(), term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def resolve_tool_run(invocation_id, run_id, decision, server \\ __MODULE__) do
    GenServer.call(server, {:resolve_tool_run, invocation_id, run_id, decision})
  end

  @impl true
  def init(opts) do
    event_store = Keyword.get(opts, :event_store, EventStore)
    config = Keyword.get_lazy(opts, :config, &RuntimeConfig.fresh/0)

    {agent_delay_ms, simulator_opts} = simulator_policy(opts, config)

    state = %{
      projection: Persistence.restore!(event_store),
      event_store: event_store,
      agent_supervisor: Keyword.get(opts, :agent_supervisor, ReyCode.AgentSupervisor),
      agent_registry: Keyword.get(opts, :agent_registry, ReyCode.AgentRegistry),
      provider_catalog: Keyword.get(opts, :provider_catalog, Catalog),
      task_supervisor: Keyword.get(opts, :task_supervisor, ReyCode.ProviderTaskSupervisor),
      event_registry: Keyword.get(opts, :event_registry, ReyCode.EventRegistry),
      agent_monitors: %{},
      execution_queue: [],
      queued_execution_ids: MapSet.new(),
      active_executions: %{},
      limits: Options.execution_limits(opts, config.orchestration),
      agent_delay_ms: agent_delay_ms,
      simulator_opts: simulator_opts,
      config: config,
      name: Keyword.get(opts, :name, __MODULE__)
    }

    state = state |> Lifecycle.ensure_default_room() |> Lifecycle.ensure_primary_participants()
    {:ok, state, {:continue, :recover}}
  end

  # Simulator pacing is frozen once at startup: explicit engine options win,
  # otherwise the injected configuration decides. The scenario delay defaults
  # to the resolved agent delay so squad and regular turns stay in step.
  defp simulator_policy(opts, config) do
    agent_delay_ms =
      Keyword.get(opts, :agent_delay_ms) || config.orchestration.agent_delay_ms

    simulator_opts =
      Keyword.get_lazy(opts, :simulator_opts, fn ->
        Keyword.put_new(config.squad.simulator, :delay_ms, agent_delay_ms)
      end)

    {agent_delay_ms, simulator_opts}
  end

  @impl true
  def handle_continue(:recover, state) do
    state = Lifecycle.recover_invocations(state)

    state =
      state.projection.room_order
      |> Enum.reduce(state, fn room_id, acc -> Lifecycle.recover_room(acc, room_id) end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.projection, state}
  def handle_call(:event_registry, _from, state), do: {:reply, state.event_registry, state}

  def handle_call({:create_room, raw_title, workspace}, _from, state),
    do: Rooms.create(state, raw_title, workspace)

  def handle_call({:create_session, source_room_id, title}, _from, state),
    do: Rooms.create_session(state, source_room_id, title)

  def handle_call({:run_owner_command, room_id, command}, _from, state),
    do: OwnerCommand.run(state, room_id, command)

  def handle_call({:add_task_participant, room_id, name, responsibility}, _from, state),
    do: Rooms.add_task_participant(state, room_id, name, responsibility)

  def handle_call({:post_message, room_id, raw_body, mode}, _from, state),
    do: Turns.post_message(state, room_id, raw_body, mode)

  def handle_call({:delegate_task, room_id, participant_id, task}, _from, state),
    do: Turns.delegate_task(state, room_id, participant_id, task)

  def handle_call(
        {:configure_participants, room_id, participant_ids, provider, model},
        _from,
        state
      ),
      do: Rooms.configure_participants(state, room_id, participant_ids, provider, model)

  def handle_call({:resolve_tool_run, invocation_id, run_id, raw_decision}, _from, state),
    do: Loop.resolve_tool_run(state, invocation_id, run_id, raw_decision)

  def handle_call({:configure_squad_roles, room_id, role_ids, provider, model}, _from, state),
    do: Rooms.configure_squad_roles(state, room_id, role_ids, provider, model)

  def handle_call({:invocation_request, invocation_id}, _from, state),
    do: Loop.request(state, invocation_id)

  def handle_call({:invocation_started, invocation_id}, _from, state),
    do: Loop.started(state, invocation_id)

  def handle_call({:record_frames, invocation_id, frames}, _from, state),
    do: Loop.record_frames(state, invocation_id, frames)

  def handle_call({:record_frame, invocation_id, frame}, _from, state),
    do: Loop.record_frame(state, invocation_id, frame)

  def handle_call({:record_round, invocation_id, round_index, response_wire}, _from, state),
    do: Loop.record_round(state, invocation_id, round_index, response_wire)

  def handle_call({:take_tool_run, invocation_id}, _from, state),
    do: Loop.take_tool_run(state, invocation_id)

  def handle_call({:tool_run_started, invocation_id, run_id}, _from, state),
    do: Loop.tool_run_started(state, invocation_id, run_id)

  def handle_call({:tool_run_completed, invocation_id, run_id, result}, _from, state),
    do: Loop.tool_run_completed(state, invocation_id, run_id, result)

  def handle_call({:tool_run_failed, invocation_id, run_id, error}, _from, state),
    do: Loop.tool_run_failed(state, invocation_id, run_id, error)

  def handle_call({:complete_invocation, invocation_id, metadata}, _from, state),
    do: Loop.complete(state, invocation_id, metadata)

  def handle_call({:fail_invocation, invocation_id, error}, _from, state),
    do: Loop.fail(state, invocation_id, error)

  def handle_call({:cancel_turn, turn_id, reason}, _from, state),
    do: Turns.cancel(state, turn_id, reason)

  def handle_call({:add_squad_directive, turn_id, raw_directive}, _from, state),
    do: Turns.add_squad_directive(state, turn_id, raw_directive)

  def handle_call(
        {:resolve_gate, turn_id, review_id, raw_decision, raw_target_phase, raw_reasons},
        _from,
        state
      ),
      do:
        Turns.resolve_gate(
          state,
          turn_id,
          review_id,
          raw_decision,
          raw_target_phase,
          raw_reasons
        )

  def handle_info({:owner_command_result, room_id, message_id, command, result}, state),
    do: OwnerCommand.finish(state, room_id, message_id, command, result)

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.agent_monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {invocation_id, monitors} ->
        state = %{state | agent_monitors: monitors}
        invocation = state.projection.invocations[invocation_id]

        case WorkerExit.classify(invocation, reason, &Lifecycle.replayable?/1) do
          :ignore ->
            {:noreply, state}

          :release ->
            # A paused approval is durable: release the execution slot without
            # failing so the resolution can resume the loop.
            state
            |> Lifecycle.release_execution(invocation_id)
            |> Lifecycle.pump_admission()
            |> noreply()

          :requeue ->
            # The loop stopped for a mid-flight handoff (for example an
            # approval that raced this exit and could not enqueue while the
            # worker still held its slot): re-arm scheduling instead of
            # failing the invocation.
            state
            |> Lifecycle.release_execution(invocation_id)
            |> Admission.enqueue(invocation_id)
            |> Lifecycle.pump_admission()
            |> noreply()

          {:fail, error} ->
            state = Lifecycle.interrupt_started_runs(state, invocation)
            {:noreply, Lifecycle.finalize_invocation(state, invocation.id, {:failed, error})}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp noreply(state), do: {:noreply, state}
end
