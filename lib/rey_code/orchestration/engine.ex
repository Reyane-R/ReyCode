defmodule ReyCode.Orchestration.Engine do
  @moduledoc "Owns durable room state and schedules provider invocations."

  use GenServer

  alias ReyCode.EventStore

  alias ReyCode.Orchestration.{
    EventEntries,
    InvocationRequest,
    Projector,
    Squad,
    Validation
  }

  alias ReyCode.Orchestration.Engine.{
    Admission,
    Configuration,
    Identity,
    Options,
    Persistence
  }

  alias ReyCode.Orchestration.Workflow.Dispatcher, as: WorkflowDispatcher
  alias ReyCode.Provider.{Catalog, Frame}

  @modes [:compare, :debate, :fan_out, :squad]

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

  @doc "Queues a user message for orchestration in the requested mode."
  @spec post_message(term(), term(), term(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def post_message(room_id, body, mode, server \\ __MODULE__) do
    GenServer.call(server, {:post_message, room_id, body, mode})
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

  @doc "Records the human decision for a pending squad gate review."
  @spec resolve_gate(term(), term(), term(), term(), GenServer.server()) ::
          :ok | {:error, atom()}
  def resolve_gate(
        turn_id,
        decision,
        target_phase \\ nil,
        reasons \\ [],
        server \\ __MODULE__
      ) do
    GenServer.call(server, {:resolve_gate, turn_id, decision, target_phase, reasons})
  end

  @impl true
  def init(opts) do
    event_store = Keyword.get(opts, :event_store, EventStore)

    state = %{
      projection: Persistence.restore!(event_store),
      event_store: event_store,
      agent_supervisor: Keyword.get(opts, :agent_supervisor, ReyCode.AgentSupervisor),
      agent_registry: Keyword.get(opts, :agent_registry, ReyCode.AgentRegistry),
      event_registry: Keyword.get(opts, :event_registry, ReyCode.EventRegistry),
      provider_catalog: Keyword.get(opts, :provider_catalog, Catalog),
      agent_monitors: %{},
      execution_queue: [],
      queued_execution_ids: MapSet.new(),
      active_executions: %{},
      limits: Options.execution_limits(opts),
      agent_delay_ms: Keyword.get(opts, :agent_delay_ms),
      name: Keyword.get(opts, :name, __MODULE__)
    }

    state = ensure_default_room(state)
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    state = recover_invocations(state)

    state =
      state.projection.room_order
      |> Enum.reduce(state, fn room_id, acc -> recover_room(acc, room_id) end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.projection, state}
  def handle_call(:event_registry, _from, state), do: {:reply, state.event_registry, state}

  def handle_call({:create_room, raw_title, workspace}, _from, state) do
    case Validation.room(raw_title, workspace) do
      {:ok, title, workspace} ->
        room_id = Identity.new_id("room")
        slug = Identity.unique_slug(Identity.slugify(title), state.projection)

        {type, payload, metadata} =
          EventEntries.room_created(
            room_id,
            slug,
            title,
            workspace,
            Options.default_participants()
          )

        next = Persistence.append_and_apply!(state, [{type, payload, metadata}])
        {:reply, {:ok, room_id}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:post_message, room_id, raw_body, mode}, _from, state) do
    cond do
      not Map.has_key?(state.projection.rooms, room_id) ->
        {:reply, {:error, :room_not_found}, state}

      mode not in @modes ->
        {:reply, {:error, :invalid_mode}, state}

      true ->
        room = state.projection.rooms[room_id]

        with {:ok, body} <- Validation.message(raw_body),
             :ok <- runtime_preflight(room, mode, state),
             :ok <- Admission.admit_turn(room, state) do
          queue_message(state, room_id, body, mode)
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:configure_participants, room_id, participant_ids, provider, model},
        _from,
        state
      ) do
    state.projection
    |> Configuration.participants(
      room_id,
      participant_ids,
      provider,
      model,
      state.provider_catalog
    )
    |> apply_configuration(state)
  end

  def handle_call({:configure_squad_roles, room_id, role_ids, provider, model}, _from, state) do
    state.projection
    |> Configuration.squad_roles(room_id, role_ids, provider, model, state.provider_catalog)
    |> apply_configuration(state)
  end

  def handle_call({:invocation_request, invocation_id}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    reply =
      cond do
        invocation == nil -> {:terminal, :missing}
        invocation.status in [:completed, :failed, :cancelled] -> {:terminal, invocation.status}
        true -> {:ok, InvocationRequest.build(invocation, state.projection, state.agent_delay_ms)}
      end

    {:reply, reply, state}
  end

  def handle_call({:invocation_started, invocation_id}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    if invocation && invocation.status == :queued do
      {:reply, :ok,
       Persistence.append_and_apply!(state, [EventEntries.invocation_started(invocation)])}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:record_frames, invocation_id, frames}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      not is_list(frames) ->
        {:reply, {:error, :invalid_frames}, state}

      true ->
        case collect_provider_frames(invocation, frames) do
          {:ok, []} ->
            {:reply, :ok, state}

          {:ok, pending_frames} ->
            append_pending_frames(state, invocation, pending_frames)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:record_frame, invocation_id, frame}, from, state) do
    handle_call({:record_frames, invocation_id, [frame]}, from, state)
  end

  def handle_call({:complete_invocation, invocation_id, metadata}, _from, state) do
    {:reply, :ok, finalize_invocation(state, invocation_id, {:completed, metadata})}
  end

  def handle_call({:fail_invocation, invocation_id, error}, _from, state) do
    {:reply, :ok, finalize_invocation(state, invocation_id, {:failed, error})}
  end

  def handle_call({:cancel_turn, turn_id, reason}, _from, state) do
    case cancel_turn_state(state, turn_id, reason) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:add_squad_directive, turn_id, raw_directive}, _from, state) do
    turn = state.projection.turns[turn_id]

    case Validation.squad_directive(turn, raw_directive) do
      {:ok, directive} ->
        {:reply, :ok,
         Persistence.append_and_apply!(state, [EventEntries.squad_directive(turn, directive)])}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:resolve_gate, turn_id, raw_decision, raw_target_phase, raw_reasons},
        _from,
        state
      ) do
    turn = state.projection.turns[turn_id]

    case Validation.gate_resolution(turn, raw_decision, raw_target_phase, raw_reasons) do
      {:ok, review, decision, target_phase, reasons} ->
        entry = EventEntries.gate_resolved(turn, review, decision, target_phase, reasons)
        next = state |> Persistence.append_and_apply!([entry]) |> advance_turn(turn.id)
        {:reply, :ok, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.agent_monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {invocation_id, monitors} ->
        state = %{state | agent_monitors: monitors}
        invocation = state.projection.invocations[invocation_id]

        if invocation == nil or invocation.status in [:completed, :failed, :cancelled] do
          {:noreply, state}
        else
          error = %{
            "category" => "worker_exit",
            "message" => "Provider worker exited before recording a result: #{inspect(reason)}",
            "retryable" => replayable?(invocation.participant.provider)
          }

          {:noreply, finalize_invocation(state, invocation.id, {:failed, error})}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp append_pending_frames(state, invocation, pending_frames) do
    if invocation.status in [:completed, :failed, :cancelled] do
      {:reply, {:error, :invocation_terminal}, state}
    else
      entries = Enum.map(pending_frames, &EventEntries.provider_frame(invocation, &1))
      {:reply, :ok, Persistence.append_and_apply!(state, entries)}
    end
  end

  defp collect_provider_frames(invocation, frames) do
    frames
    |> Enum.reduce_while({:ok, [], invocation.last_frame_sequence}, &collect_provider_frame/2)
    |> case do
      {:ok, pending, _cursor} -> {:ok, Enum.reverse(pending)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_provider_frame(frame, {:ok, accepted, cursor}) do
    if Frame.validate(frame) != :ok do
      {:halt, {:error, :invalid_frame}}
    else
      cond do
        frame.sequence <= cursor ->
          {:cont, {:ok, accepted, cursor}}

        frame.sequence == cursor + 1 ->
          {:cont, {:ok, [frame | accepted], cursor + 1}}

        true ->
          {:halt, {:error, :invalid_frame_sequence}}
      end
    end
  end

  defp ensure_default_room(%{projection: %{room_order: []}} = state) do
    room_id = "room-reycode"

    {type, payload, metadata} =
      EventEntries.room_created(
        room_id,
        "reycode",
        "ReyCode",
        File.cwd!(),
        Options.default_participants()
      )

    Persistence.append_and_project!(state, [{type, payload, metadata}])
  end

  defp ensure_default_room(state), do: state

  defp queue_message(state, room_id, body, mode) do
    turn_id = Identity.new_id("turn")
    message_id = Identity.new_id("msg")
    context_sequence = state.projection.sequence + 1

    entries = EventEntries.queue_turn(room_id, body, mode, turn_id, message_id, context_sequence)

    next = Persistence.append_and_apply!(state, entries)
    room = next.projection.rooms[room_id]
    next = if room.active_turn_id == nil, do: start_turn(next, turn_id), else: next
    {:reply, {:ok, turn_id}, next}
  end

  defp cancel_turn_state(state, turn_id, reason) do
    turn = state.projection.turns[turn_id]

    case Validation.cancellation(turn, reason) do
      {:ok, reason} when is_binary(reason) -> cancel_turn_invocations(state, turn, reason)
      {:ok, :already_finished} -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp cancel_turn_invocations(state, turn, reason) do
    invocations = cancellable_turn_invocations(state, turn)
    invocation_ids = Enum.map(invocations, & &1.id)

    next =
      state
      |> persist_turn_cancellation(turn, invocations, reason)
      |> Admission.drop_executions(invocation_ids)
      |> kill_cancelled_executions(invocation_ids)
      |> start_next_queued_turn(turn.room_id)
      |> pump_admission()

    {:ok, next}
  end

  defp cancellable_turn_invocations(state, turn) do
    turn.invocation_order
    |> Enum.map(&state.projection.invocations[&1])
    |> Enum.filter(&(&1.status in [:queued, :running]))
  end

  defp persist_turn_cancellation(state, turn, invocations, reason) do
    Persistence.append_and_apply!(state, EventEntries.cancel_turn(turn, invocations, reason))
  end

  defp kill_execution(state, invocation_id) do
    case Registry.lookup(state.agent_registry, invocation_id) do
      [{pid, _value} | _] -> Process.exit(pid, :kill)
      [] -> :ok
    end
  end

  defp kill_cancelled_executions(state, invocation_ids) do
    Enum.each(invocation_ids, &kill_execution(state, &1))
    state
  end

  defp start_next_queued_turn(state, room_id) do
    room = state.projection.rooms[room_id]

    if room.active_turn_id == nil and room.queued_turn_ids != [] do
      start_turn(state, hd(room.queued_turn_ids))
    else
      state
    end
  end

  defp runtime_preflight(room, :squad, state) do
    configured = Map.get(room, :squad_roles, %{})

    missing =
      Squad.roles()
      |> Enum.reject(fn role ->
        case configured[role.id] do
          nil -> false
          participant -> runtime_ready?(participant, state)
        end
      end)
      |> Enum.map(& &1.id)

    if missing == [], do: :ok, else: {:error, {:squad_roles_unconfigured, missing}}
  end

  defp runtime_preflight(room, _mode, state) do
    missing =
      room.participants
      |> Enum.reject(&runtime_ready?(&1, state))
      |> Enum.map(& &1.id)

    if missing == [], do: :ok, else: {:error, {:participants_unconfigured, missing}}
  end

  defp runtime_ready?(participant, state) do
    match?(
      {:ok, _runtime},
      Catalog.resolve(participant.provider, participant.model, state.provider_catalog)
    )
  end

  defp apply_configuration({:ok, entries}, state) do
    {:reply, :ok, Persistence.append_and_apply!(state, entries)}
  end

  defp apply_configuration({:error, reason}, state), do: {:reply, {:error, reason}, state}

  defp recover_room(state, room_id) do
    room = state.projection.rooms[room_id]

    cond do
      room.active_turn_id != nil -> recover_active_turn(state, room.active_turn_id)
      room.queued_turn_ids != [] -> start_turn(state, hd(room.queued_turn_ids))
      true -> state
    end
  end

  defp recover_active_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]

    if turn.invocation_order == [],
      do: start_initial_invocations(state, turn),
      else: advance_turn(state, turn_id)
  end

  defp start_initial_invocations(state, turn) do
    room = state.projection.rooms[turn.room_id]
    workflow = WorkflowDispatcher.for_mode(turn.mode)
    open_invocations(state, turn, workflow.plan(room, turn, state.projection))
  end

  defp recover_invocations(state) do
    state.projection.invocations
    |> Map.values()
    |> Enum.sort_by(fn invocation ->
      state.projection.messages[invocation.message_id].created_sequence
    end)
    |> Enum.reduce(state, &recover_invocation(&2, &1))
    |> pump_admission()
  end

  defp recover_invocation(state, %{status: status}) when status not in [:queued, :running],
    do: state

  defp recover_invocation(state, %{status: :running} = invocation) do
    case Registry.lookup(state.agent_registry, invocation.id) do
      [{pid, _} | _] ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
        recover_missing_execution(state, invocation)

      [] ->
        recover_missing_execution(state, invocation)
    end
  end

  defp recover_invocation(state, %{status: :queued} = invocation) do
    case Registry.lookup(state.agent_registry, invocation.id) do
      [{pid, _} | _] ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
        Admission.enqueue(state, invocation.id)

      [] ->
        Admission.enqueue(state, invocation.id)
    end
  end

  defp recover_missing_execution(state, invocation) do
    if replayable?(invocation.participant.provider) do
      Admission.enqueue(state, invocation.id)
    else
      error = %{
        "category" => "interrupted",
        "message" => "The provider invocation was interrupted and cannot be replayed safely",
        "retryable" => true
      }

      finalize_invocation(state, invocation.id, {:failed, error})
    end
  end

  defp start_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]
    room = state.projection.rooms[turn.room_id]
    specs = WorkflowDispatcher.for_mode(turn.mode).plan(room, turn, state.projection)
    invocation_entries = build_invocation_entries(room, turn, specs)

    turn_entry = EventEntries.turn_started(turn)

    state =
      if turn.mode == :squad do
        squad_config = [
          rework_budget: Application.get_env(:rey_code, :squad_rework_budget, Squad.max_rework()),
          seed: Application.get_env(:rey_code, :squad_seed, 0)
        ]

        Persistence.append_and_apply!(
          state,
          [turn_entry | EventEntries.squad_start(turn, squad_config)] ++ invocation_entries
        )
      else
        Persistence.append_and_apply!(state, [turn_entry | invocation_entries])
      end

    start_invocation_workers(state, invocation_entries)
  end

  defp advance_turn(state, turn_id) do
    turn = state.projection.turns[turn_id]
    room = state.projection.rooms[turn.room_id]

    case WorkflowDispatcher.for_mode(turn.mode).advance(room, turn, state.projection) do
      :wait ->
        state

      {:continue, specs} ->
        open_invocations(state, turn, specs)

      {:complete, outcome} ->
        entry = EventEntries.turn_completed(turn, outcome)

        state = Persistence.append_and_apply!(state, [entry])
        room = state.projection.rooms[turn.room_id]

        if room.queued_turn_ids == [] do
          state
        else
          start_turn(state, hd(room.queued_turn_ids))
        end
    end
  end

  defp open_invocations(state, turn, specs) do
    room = state.projection.rooms[turn.room_id]
    entries = build_invocation_entries(room, turn, specs)

    state =
      if turn.mode == :squad do
        Persistence.append_and_apply!(state, EventEntries.squad_continue(turn, specs) ++ entries)
      else
        Persistence.append_and_apply!(state, entries)
      end

    start_invocation_workers(state, entries)
  end

  defp build_invocation_entries(room, turn, specs) do
    generated_ids =
      Enum.map(specs, fn _spec -> {Identity.new_id("inv"), Identity.new_id("msg")} end)

    EventEntries.open_invocations(room, turn, specs, generated_ids)
  end

  defp start_invocation_workers(state, entries) do
    entries
    |> Enum.reduce(state, fn {_type, payload, _metadata}, acc ->
      Admission.enqueue(acc, payload["invocation_id"])
    end)
    |> pump_admission()
  end

  defp pump_admission(state) do
    case Admission.next_eligible(state) do
      nil ->
        state

      {invocation_id, index} ->
        state = Admission.dequeue(state, {invocation_id, index})

        invocation = state.projection.invocations[invocation_id]

        if invocation == nil or invocation.status in [:completed, :failed, :cancelled] do
          pump_admission(state)
        else
          invocation |> start_execution(state) |> pump_admission()
        end
    end
  end

  defp start_execution(invocation, state) do
    spec =
      {ReyCode.Agent,
       engine: state.name,
       registry: state.agent_registry,
       invocation_id: invocation.id,
       provider: invocation.participant.provider,
       provider_catalog: state.provider_catalog}

    case DynamicSupervisor.start_child(state.agent_supervisor, spec) do
      {:ok, pid} ->
        monitor_execution(state, invocation.id, pid)

      {:error, {:already_started, pid}} ->
        monitor_execution(state, invocation.id, pid)

      {:error, reason} ->
        error = %{
          "category" => "worker_start_failed",
          "message" => "Could not start provider worker: #{inspect(reason)}",
          "retryable" => true
        }

        finalize_invocation(state, invocation.id, {:failed, error})
    end
  end

  defp monitor_execution(state, invocation_id, pid) do
    ref = Process.monitor(pid)
    workspace = Admission.workspace(state, invocation_id)

    state
    |> put_in([:agent_monitors, ref], invocation_id)
    |> put_in([:active_executions, invocation_id], workspace)
  end

  defp release_execution(state, invocation_id) do
    %{state | active_executions: Map.delete(state.active_executions, invocation_id)}
  end

  defp finalize_invocation(state, invocation_id, outcome) do
    state = release_execution(state, invocation_id)
    invocation = state.projection.invocations[invocation_id]

    next =
      if invocation == nil or invocation.status in [:completed, :failed, :cancelled] do
        state
      else
        turn = state.projection.turns[invocation.turn_id]
        message = state.projection.messages[invocation.message_id]

        opts = [
          human_release_review?: Application.get_env(:rey_code, :squad_release_gate_human, true)
        ]

        turn.mode
        |> WorkflowDispatcher.for_mode()
        |> then(& &1.finalize(invocation, message, outcome, opts))
        |> apply_finalization(state, invocation)
      end

    pump_admission(next)
  end

  defp apply_finalization({:advance, entries}, state, invocation) do
    state |> Persistence.append_and_apply!(entries) |> advance_turn(invocation.turn_id)
  end

  defp apply_finalization({:retry, entries, retry_spec}, state, invocation) do
    turn = state.projection.turns[invocation.turn_id]
    room = state.projection.rooms[invocation.room_id]
    invocation_entries = build_invocation_entries(room, turn, [retry_spec])

    next = Persistence.append_and_apply!(state, entries ++ invocation_entries)
    start_invocation_workers(next, invocation_entries)
  end

  defp replayable?(:simulator), do: true
  defp replayable?("simulator"), do: true
  defp replayable?(_provider), do: false
end
