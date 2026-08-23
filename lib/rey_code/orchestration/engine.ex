defmodule ReyCode.Orchestration.Engine do
  @moduledoc "Owns durable room state and schedules provider invocations."

  use GenServer

  alias ReyCode.EventStore

  alias ReyCode.Orchestration.{
    EventEntries,
    InvocationRequest,
    Projector,
    Squad,
    ToolRuns,
    Validation
  }

  alias ReyCode.Orchestration.Engine.{
    Admission,
    Configuration,
    Identity,
    Lifecycle,
    Options,
    Persistence,
    ProviderFrames,
    WorkerExit
  }

  alias ReyCode.Provider.{Catalog, Response}
  alias ReyCode.RuntimeConfig
  alias ReyCode.ToolRegistry

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
      event_registry: Keyword.get(opts, :event_registry, ReyCode.EventRegistry),
      provider_catalog: Keyword.get(opts, :provider_catalog, Catalog),
      agent_monitors: %{},
      execution_queue: [],
      queued_execution_ids: MapSet.new(),
      active_executions: %{},
      limits: Options.execution_limits(opts, config),
      agent_delay_ms: agent_delay_ms,
      simulator_opts: simulator_opts,
      config: config,
      name: Keyword.get(opts, :name, __MODULE__)
    }

    state = Lifecycle.ensure_default_room(state)
    {:ok, state, {:continue, :recover}}
  end

  # Simulator pacing is frozen once at startup: explicit engine options win,
  # otherwise the injected configuration decides. The scenario delay defaults
  # to the resolved agent delay so squad and regular turns stay in step.
  defp simulator_policy(opts, config) do
    agent_delay_ms =
      Keyword.get(opts, :agent_delay_ms) || RuntimeConfig.policy(config, :agent_delay_ms, 0)

    simulator_opts =
      Keyword.get_lazy(opts, :simulator_opts, fn ->
        config
        |> RuntimeConfig.policy(:squad_simulator, [])
        |> Keyword.put_new(:delay_ms, agent_delay_ms)
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

  def handle_call({:create_room, raw_title, workspace}, _from, state) do
    case Validation.room(raw_title, workspace, config: state.config) do
      {:ok, title, workspace} ->
        room_id = Identity.new_id("room")
        slug = Identity.unique_slug(Identity.slugify(title), state.projection)

        {type, payload, metadata} =
          EventEntries.room_created(
            room_id,
            slug,
            title,
            workspace,
            Options.default_participants(state.config)
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
          Lifecycle.queue_message(state, room_id, body, mode)
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
      state.provider_catalog,
      state.config
    )
    |> apply_configuration(state)
  end

  def handle_call({:resolve_tool_run, invocation_id, run_id, raw_decision}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    with {:ok, review, decision} <-
           Validation.tool_run_resolution(invocation, run_id, raw_decision),
         {:ok, run} <- resumable_run(invocation, review) do
      {:reply, :ok, resolve_tool_decision(state, invocation, run, decision)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:configure_squad_roles, room_id, role_ids, provider, model}, _from, state) do
    state.projection
    |> Configuration.squad_roles(
      room_id,
      role_ids,
      provider,
      model,
      state.provider_catalog,
      state.config
    )
    |> apply_configuration(state)
  end

  def handle_call({:invocation_request, invocation_id}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    reply =
      cond do
        invocation == nil ->
          {:terminal, :missing}

        invocation.status in [:completed, :failed, :cancelled] ->
          {:terminal, invocation.status}

        ToolRuns.awaiting?(invocation) ->
          {:waiting, :tool_approval}

        invocation.status == :waiting_tool_approval ->
          {:waiting, :tool_approval}

        true ->
          {:ok,
           InvocationRequest.build(invocation, state.projection, %{
             agent_delay_ms: state.agent_delay_ms,
             simulator_opts: state.simulator_opts
           })}
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
        case ProviderFrames.collect(invocation, frames) do
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

  def handle_call({:record_round, invocation_id, round_index, response_wire}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      invocation.status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :invocation_terminal}, state}

      true ->
        record_round(state, invocation, round_index, response_wire)
    end
  end

  def handle_call({:take_tool_run, invocation_id}, _from, state) do
    invocation = state.projection.invocations[invocation_id]

    cond do
      invocation == nil ->
        {:reply, {:error, :invocation_not_found}, state}

      invocation.status in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :invocation_terminal}, state}

      true ->
        take_tool_run(state, invocation)
    end
  end

  def handle_call({:tool_run_started, invocation_id, run_id}, _from, state) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :ready) do
      entry = EventEntries.tool_run_started(invocation, run)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tool_run_completed, invocation_id, run_id, result}, _from, state) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :running),
         :ok <- ensure_wire_map(result) do
      entry = EventEntries.tool_run_completed(invocation, run, result)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tool_run_failed, invocation_id, run_id, error}, _from, state) do
    with {:ok, invocation} <- fetch_invocation(state, invocation_id),
         {:ok, run} <- ToolRuns.fetch_for_transition(invocation, run_id, :running),
         :ok <- ensure_wire_map(error) do
      entry = EventEntries.tool_run_failed(invocation, run, error)
      {:reply, :ok, Persistence.append_and_apply!(state, [entry])}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:complete_invocation, invocation_id, metadata}, _from, state) do
    {:reply, :ok, Lifecycle.finalize_invocation(state, invocation_id, {:completed, metadata})}
  end

  def handle_call({:fail_invocation, invocation_id, error}, _from, state) do
    {:reply, :ok, Lifecycle.finalize_invocation(state, invocation_id, {:failed, error})}
  end

  def handle_call({:cancel_turn, turn_id, reason}, _from, state) do
    case Lifecycle.cancel_turn(state, turn_id, reason) do
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
        {:resolve_gate, turn_id, review_id, raw_decision, raw_target_phase, raw_reasons},
        _from,
        state
      ) do
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

  defp append_pending_frames(state, invocation, pending_frames) do
    if invocation.status in [:completed, :failed, :cancelled] do
      {:reply, {:error, :invocation_terminal}, state}
    else
      entries = Enum.map(pending_frames, &EventEntries.provider_frame(invocation, &1))
      {:reply, :ok, Persistence.append_and_apply!(state, entries)}
    end
  end

  defp record_round(state, invocation, round_index, response_wire) do
    with {:ok, response} <- Response.from_wire(response_wire),
         :ok <- round_contiguous?(invocation, round_index) do
      entry = EventEntries.provider_round(invocation, round_index, response_wire)
      state = Persistence.append_and_apply!(state, [entry])

      if response.tool_calls == [] do
        {:reply, {:ok, :final}, state}
      else
        {:reply, {:ok, :continue}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp round_contiguous?(invocation, round_index) do
    if round_index == length(invocation.rounds),
      do: :ok,
      else: {:error, :invalid_round_index}
  end

  defp take_tool_run(state, invocation) do
    case ToolRuns.next_action(invocation) do
      :none ->
        {:reply, {:ok, :none}, state}

      {:new, call} ->
        claim_new_run(state, invocation, call)

      {:existing, action, run} ->
        {:reply, {:ok, {action, run}}, state}
    end
  end

  defp claim_new_run(state, invocation, call) do
    run = %{
      id: Identity.new_id("toolrun"),
      tool_call_id: call.id,
      round_index: length(invocation.rounds) - 1,
      tool: call.tool,
      arguments: call.arguments,
      workspace: Path.expand(state.projection.rooms[invocation.room_id].workspace)
    }

    authorization =
      if ToolRegistry.requires_approval?(call.tool) do
        :ask
      else
        if call.tool in ToolRegistry.tool_names(), do: :allow, else: :denied
      end

    run = Map.put(run, :authorization, authorization)

    entries =
      case authorization do
        :denied ->
          [
            EventEntries.tool_run_requested(invocation, run),
            EventEntries.tool_run_failed(invocation, run, %{
              "ok" => false,
              "error" => "unknown_tool"
            })
          ]

        _other ->
          [EventEntries.tool_run_requested(invocation, run)]
      end

    next = Persistence.append_and_apply!(state, entries)
    run = next.projection.invocations[invocation.id].tool_runs[run.id]

    next =
      if authorization == :ask,
        do: Lifecycle.advance_turn(next, invocation.turn_id),
        else: next

    action = if authorization == :denied, do: :denied, else: authorization_action(authorization)
    {:reply, {:ok, {action, run}}, next}
  end

  defp authorization_action(:allow), do: :execute
  defp authorization_action(:ask), do: :await

  defp fetch_invocation(state, invocation_id) do
    case state.projection.invocations[invocation_id] do
      nil -> {:error, :invocation_not_found}
      invocation -> {:ok, invocation}
    end
  end

  defp ensure_wire_map(value) when is_map(value), do: :ok
  defp ensure_wire_map(_value), do: {:error, :invalid_tool_run_payload}

  defp resumable_run(invocation, review) do
    case Map.get(invocation.tool_runs, review.request_id) do
      %{status: :awaiting_approval} = run ->
        {:ok, run}

      _other ->
        {:error, :legacy_tool_approval_unresumable}
    end
  end

  defp resolve_tool_decision(state, invocation, run, :approve) do
    entry = EventEntries.tool_run_approval_resolved(invocation, run, :approve)

    state
    |> Persistence.append_and_apply!([entry])
    |> Admission.enqueue(invocation.id)
    |> Lifecycle.pump_admission()
  end

  # A denial and its terminal failure must share one durable transaction:
  # persisting them separately could crash between the writes and strand the
  # invocation in :waiting_tool_approval with no review left to resolve.
  defp resolve_tool_decision(state, invocation, run, :deny) do
    denial = EventEntries.tool_run_approval_resolved(invocation, run, :deny)

    Lifecycle.finalize_invocation(state, invocation.id, {:failed, tool_denied_error()}, [denial])
  end

  defp tool_denied_error do
    %{
      "category" => "tool_denied",
      "message" => "Tool request denied",
      "retryable" => false
    }
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
end
