defmodule ReyCode.Orchestration.Engine do
  @moduledoc "Owns durable session state and schedules provider invocations."

  use GenServer

  alias ReyCode.EventStore

  alias ReyCode.Orchestration.Projector

  alias ReyCode.Orchestration.Engine.{
    DelegationFinalization,
    Execution,
    Lifecycle,
    Loop,
    Options,
    OwnerCommand,
    Persistence,
    Sessions,
    Turns
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
  Subscribes the caller to projection broadcasts and returns the baseline.

  Registration and snapshot are separate steps: a broadcast dispatched after
  registration but before this reply can sit ahead of the returned baseline
  in the caller's mailbox. Every notification carries a projection whose
  `sequence` strictly increases with each committed batch, so consumers hold
  the sequence of their current projection and ignore notifications at or
  below it. Honoring that contract makes the observed stream monotonic from
  the returned baseline.
  """
  def subscribe(server \\ __MODULE__) do
    event_registry = GenServer.call(server, :event_registry)
    ensure_registered(event_registry, :orchestration)

    snapshot(server)
  end

  # Duplicate registries append another entry when the same pid registers
  # twice, so re-subscription checks the existing registration instead.
  defp ensure_registered(registry, key) do
    unless Enum.any?(Registry.lookup(registry, key), fn {pid, _value} -> pid == self() end) do
      {:ok, _pid} = Registry.register(registry, key, nil)
    end

    :ok
  end

  @doc "Creates a session rooted at a workspace and returns its ID."
  @spec create_blank_session(term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, atom()}
  def create_blank_session(title, workspace \\ File.cwd!(), server \\ __MODULE__) do
    GenServer.call(server, {:create_blank_session, title, workspace})
  end

  @doc "Creates a fresh durable session titled from its first input."
  @spec create_session(term(), term(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def create_session(source_session_id, title, server \\ __MODULE__) do
    GenServer.call(server, {:create_session, source_session_id, title})
  end

  @doc "Forks a Session at one immutable Projection sequence."
  @spec fork_session(term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, atom()}
  def fork_session(source_session_id, through_sequence, server \\ __MODULE__) do
    GenServer.call(server, {:fork_session, source_session_id, through_sequence})
  end

  @doc "Runs one owner-typed shell command and records its transcript message."
  @spec run_owner_command(term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def run_owner_command(session_id, command, server \\ __MODULE__) do
    GenServer.call(server, {:run_owner_command, session_id, command})
  end

  @doc "Adds one durable task participant to a session."
  @spec add_task_participant(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, atom()}
  def add_task_participant(session_id, name, responsibility, server \\ __MODULE__) do
    GenServer.call(server, {:add_task_participant, session_id, name, responsibility})
  end

  @doc "Queues a user message for orchestration in the requested mode."
  @spec post_message(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def post_message(session_id, body, mode, server \\ __MODULE__) do
    GenServer.call(server, {:post_message, session_id, body, mode})
  end

  @doc "Queues one Operator correction for the next provider-round boundary."
  @spec steer_turn(term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def steer_turn(turn_id, body, server \\ __MODULE__) do
    GenServer.call(server, {:steer_turn, turn_id, body})
  end

  @doc "Cancels and returns the newest queued FollowUp body in one Session."
  @spec dequeue_latest_follow_up(term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, atom()}
  def dequeue_latest_follow_up(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:dequeue_latest_follow_up, session_id})
  end

  @doc "Queues a new Turn linked to one failed terminal Turn."
  @spec retry_turn(term(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def retry_turn(turn_id, server \\ __MODULE__) do
    GenServer.call(server, {:retry_turn, turn_id})
  end

  @doc "Queues one explicit task for one task participant."
  @spec delegate_task(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def delegate_task(session_id, participant_id, task, server \\ __MODULE__) do
    GenServer.call(server, {:delegate_task, session_id, participant_id, task})
  end

  @doc "Records one OperatorQuestion answer selection."
  @spec answer_question(String.t(), String.t(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def answer_question(invocation_id, question_id, selection, server \\ __MODULE__) do
    GenServer.call(server, {:answer_question, invocation_id, question_id, selection})
  end

  @doc "Applies or discards one pending isolated delegation patch."
  @spec resolve_merge(String.t(), atom() | String.t(), GenServer.server()) ::
          :ok | {:error, atom()}
  def resolve_merge(child_invocation_id, decision, server \\ __MODULE__) do
    GenServer.call(server, {:resolve_merge, child_invocation_id, decision}, :infinity)
  end

  @doc "Cancels an unfinished turn and its outstanding provider invocations."
  @spec cancel_turn(term(), term(), GenServer.server()) :: :ok | {:error, atom()}
  def cancel_turn(turn_id, reason \\ "Cancelled by user", server \\ __MODULE__) do
    GenServer.call(server, {:cancel_turn, turn_id, reason}, :infinity)
  end

  @doc "Assigns a provider and model to selected session participants."
  @spec configure_participants(term(), term(), term(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def configure_participants(session_id, participant_ids, provider, model, server \\ __MODULE__) do
    GenServer.call(
      server,
      {:configure_participants, session_id, participant_ids, provider, model}
    )
  end

  @doc "Assigns one ModelTier to a session Participant."
  @spec configure_participant_tier(term(), term(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def configure_participant_tier(session_id, participant_id, tier, server \\ __MODULE__) do
    GenServer.call(server, {:configure_participant_tier, session_id, participant_id, tier})
  end

  @doc "Assigns a provider and model to selected squad roles in a session."
  @spec configure_squad_roles(term(), term(), term(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def configure_squad_roles(session_id, role_ids, provider, model, server \\ __MODULE__) do
    GenServer.call(server, {:configure_squad_roles, session_id, role_ids, provider, model})
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

    state = state |> Lifecycle.ensure_default_session() |> Lifecycle.ensure_primary_participants()
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
  def handle_continue(:recover, state), do: {:noreply, Execution.recover(state)}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.projection, state}
  def handle_call(:event_registry, _from, state), do: {:reply, state.event_registry, state}

  def handle_call({:create_blank_session, raw_title, workspace}, _from, state),
    do: Sessions.create(state, raw_title, workspace)

  def handle_call({:create_session, source_session_id, title}, _from, state),
    do: Sessions.create_session(state, source_session_id, title)

  def handle_call({:fork_session, source_session_id, through_sequence}, _from, state),
    do: Sessions.fork_session(state, source_session_id, through_sequence)

  def handle_call({:run_owner_command, session_id, command}, _from, state),
    do: OwnerCommand.run(state, session_id, command)

  def handle_call({:add_task_participant, session_id, name, responsibility}, _from, state),
    do: Sessions.add_task_participant(state, session_id, name, responsibility)

  def handle_call({:post_message, session_id, raw_body, mode}, _from, state),
    do: Turns.post_message(state, session_id, raw_body, mode)

  def handle_call({:steer_turn, turn_id, raw_body}, _from, state),
    do: Turns.steer(state, turn_id, raw_body)

  def handle_call({:dequeue_latest_follow_up, session_id}, _from, state),
    do: Turns.dequeue_latest_follow_up(state, session_id)

  def handle_call({:retry_turn, turn_id}, _from, state), do: Turns.retry(state, turn_id)

  def handle_call({:delegate_task, session_id, participant_id, task}, _from, state),
    do: Turns.delegate_task(state, session_id, participant_id, task)

  def handle_call({:answer_question, invocation_id, question_id, option_id}, _from, state),
    do: Loop.answer_question(state, invocation_id, question_id, option_id)

  def handle_call(
        {:configure_participants, session_id, participant_ids, provider, model},
        _from,
        state
      ),
      do: Sessions.configure_participants(state, session_id, participant_ids, provider, model)

  def handle_call({:configure_participant_tier, session_id, participant_id, tier}, _from, state),
    do: Sessions.configure_participant_tier(state, session_id, participant_id, tier)

  def handle_call({:resolve_tool_run, invocation_id, run_id, raw_decision}, _from, state),
    do: Loop.resolve_tool_run(state, invocation_id, run_id, raw_decision)

  def handle_call({:resolve_merge, child_invocation_id, decision}, _from, state),
    do: DelegationFinalization.resolve_merge(state, child_invocation_id, decision)

  def handle_call({:configure_squad_roles, session_id, role_ids, provider, model}, _from, state),
    do: Sessions.configure_squad_roles(state, session_id, role_ids, provider, model)

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

  def handle_info({:owner_command_result, session_id, message_id, command, result}, state),
    do: OwnerCommand.finish(state, session_id, message_id, command, result)

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, Execution.apply_worker_exit(state, ref, reason)}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
