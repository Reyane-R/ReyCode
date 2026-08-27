defmodule ReyCode.Orchestration.Projector do
  @moduledoc "Pure projection of room orchestration events."

  # Activity-trail bound: newest agent notes win when the invocation exceeds it.
  @max_invocation_notes 100

  import Kernel, except: [apply: 2]

  alias ReyCode.{Event, Failure}
  alias ReyCode.ProjectInstructions.Capture

  alias ReyCode.Orchestration.{
    Author,
    Invocation,
    InvocationExecution,
    Message,
    Mode,
    Participant,
    Projection,
    ProviderRound,
    Room,
    SquadRun,
    Steering,
    ToolAsk,
    ToolRun,
    Turn
  }

  alias ReyCode.Orchestration.Squad.{
    Artifact,
    Directive,
    GateRecommendation,
    GateResolution,
    GateReview,
    Retry,
    Seat
  }

  alias ReyCode.Provider.Registry

  @type state :: Projection.t()

  @spec initial() :: state()
  def initial, do: %Projection{}

  @spec replay([Event.t()]) :: state()
  def replay(events), do: Enum.reduce(events, initial(), &apply/2)

  @spec replay([Event.t()], state()) :: state()
  def replay(events, state), do: Enum.reduce(events, Projection.from_map(state), &apply/2)

  @spec apply(Event.t(), state()) :: state()
  def apply(%Event{type: :room_created, data: data} = event, state) do
    room = %Room{
      id: data["room_id"],
      slug: data["slug"],
      title: data["title"],
      workspace: data["workspace"],
      participants: Enum.map(data["participants"], &participant/1),
      squad_seats: %{},
      message_order: [],
      active_turn_id: nil,
      queued_turn_ids: [],
      created_at: event.recorded_at
    }

    %{
      state
      | sequence: event.sequence,
        rooms: Map.put(state.rooms, room.id, room),
        room_order: state.room_order ++ [room.id]
    }
  end

  def apply(%Event{type: :session_forked, data: data} = event, state) do
    update_room(state, data["room_id"], fn room ->
      %{
        room
        | parent_room_id: data["parent_room_id"],
          forked_from_sequence: data["through_sequence"],
          message_order: data["inherited_message_ids"]
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :context_compacted, data: data} = event, state) do
    update_room(state, data["room_id"], fn room ->
      %{
        room
        | context_boundary_sequence: data["through_sequence"],
          context_summary: data["summary"],
          context_compacted_at: event.recorded_at
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :participant_added, data: data} = event, state) do
    participant =
      participant(%{
        "id" => data["participant_id"],
        "name" => data["name"],
        "perspective" => data["responsibility"],
        "provider" => data["provider"],
        "model" => data["model"],
        "kind" => data["kind"]
      })

    update_room(state, data["room_id"], fn room ->
      %{room | participants: room.participants ++ [participant]}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :participant_configured, data: data} = event, state) do
    update_room(state, data["room_id"], fn room ->
      participants =
        Enum.map(room.participants, &configure_participant(&1, data))

      %{room | participants: participants}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_role_configured, data: data} = event, state) do
    update_room(state, data["room_id"], fn room ->
      seat = %Seat{
        id: data["role_id"],
        role_id: data["role_id"],
        name: data["name"],
        perspective: data["perspective"],
        provider: provider(data["provider"]),
        model: data["model"]
      }

      %{room | squad_seats: Map.put(room.squad_seats, seat.id, seat)}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :message_posted, data: data} = event, state) do
    message = %Message{
      id: data["message_id"],
      room_id: data["room_id"],
      turn_id: data["turn_id"],
      invocation_id: nil,
      author: Author.user(data["author_name"]),
      role: :user,
      status: :completed,
      body: data["body"],
      created_at: event.recorded_at,
      created_sequence: event.sequence,
      error: nil
    }

    state
    |> put_message(message)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :turn_queued, data: data} = event, state) do
    turn = %Turn{
      id: data["turn_id"],
      room_id: data["room_id"],
      user_message_id: data["user_message_id"],
      input_kind: input_kind(data["input_kind"]),
      mode: mode(data["mode"]),
      participant_id: data["participant_id"],
      status: :queued,
      context_through_sequence: data["context_through_sequence"],
      invocation_order: [],
      outcome: nil,
      squad: nil,
      created_at: event.recorded_at
    }

    update_room(state, turn.room_id, fn room ->
      %{room | queued_turn_ids: room.queued_turn_ids ++ [turn.id]}
    end)
    |> Map.update!(:turns, &Map.put(&1, turn.id, turn))
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :turn_started, data: data} = event, state) do
    update_turn(state, data["turn_id"], &%{&1 | status: :running})
    |> update_room(data["room_id"], fn room ->
      %{
        room
        | active_turn_id: data["turn_id"],
          queued_turn_ids: List.delete(room.queued_turn_ids, data["turn_id"])
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :assistant_message_opened, data: data} = event, state) do
    participant =
      if state.turns[data["turn_id"]].mode == :squad,
        do: seat(data["participant"]),
        else: participant(data["participant"])

    message = opened_message(data, event, participant)
    invocation = opened_invocation(data, participant)

    state
    |> put_message(message)
    |> Map.update!(:invocations, &Map.put(&1, invocation.id, invocation))
    |> update_turn(invocation.turn_id, fn turn ->
      %{turn | invocation_order: turn.invocation_order ++ [invocation.id]}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :invocation_started, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], &%{&1 | status: :running})
    |> update_message(data["message_id"], &%{&1 | status: :streaming})
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :invocation_steering_requested, data: data} = event, state) do
    steering = %Steering{
      id: data["steering_id"],
      body: data["body"],
      requested_sequence: event.sequence
    }

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      %{invocation | pending_steering: invocation.pending_steering ++ [steering]}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_ask_requested, data: data} = event, state) do
    review = %ToolAsk{
      request_id: data["request_id"],
      tool: data["tool"],
      arguments: data["arguments"],
      workspace: data["workspace"],
      requested_at: event.recorded_at
    }

    state
    |> update_invocation(
      data["invocation_id"],
      &%{&1 | status: :waiting_tool_approval, pending_tool_review: review}
    )
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_ask_resolved, data: data} = event, state) do
    status = if data["decision"] == "approve", do: :running, else: :failed

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      error =
        if status == :failed,
          do: Failure.new(:tool_denied, "Tool request denied"),
          else: invocation.error

      %{invocation | status: status, pending_tool_review: nil, error: error}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :provider_frame_recorded, data: data} = event, state) do
    state
    |> apply_provider_frame(data["invocation_id"], data)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :provider_round_recorded, data: data} = event, state) do
    steering = Enum.map(data["steering"] || [], &Steering.from_map/1)

    round =
      ProviderRound.from_map(%{
        index: data["round_index"],
        text: data["text"],
        tool_calls: data["tool_calls"],
        steering: steering,
        usage: data["usage"]
      })

    consumed_ids = MapSet.new(steering, & &1.id)

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      %{
        invocation
        | rounds: invocation.rounds ++ [round],
          pending_steering:
            Enum.reject(invocation.pending_steering, &MapSet.member?(consumed_ids, &1.id)),
          usage: data["usage"] || invocation.usage
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_requested, data: data} = event, state) do
    run = %ToolRun{
      id: data["tool_run_id"],
      tool_call_id: data["tool_call_id"],
      round_index: data["round_index"],
      tool: data["tool"],
      arguments: data["arguments"],
      workspace: data["workspace"],
      workspace_roots: data["workspace_roots"] || [],
      authorization: authorization(data["authorization"]),
      status: requested_status(data["authorization"]),
      resolution: nil,
      result: nil,
      error: nil,
      requested_at: event.recorded_at,
      started_at: nil,
      completed_at: nil
    }

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      invocation
      |> Map.update!(:tool_runs, &Map.put(&1, run.id, run))
      |> Map.update!(:tool_run_order, &(&1 ++ [run.id]))
      |> awaiting_review(run)
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_approval_resolved, data: data} = event, state) do
    decision = decision(data["decision"])
    status = if decision == :approve, do: :ready, else: :denied

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      invocation
      |> update_run(data["tool_run_id"], &resolve_run(&1, status, decision))
      |> clear_review(data["tool_run_id"], decision)
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_started, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      update_run(invocation, data["tool_run_id"], fn run ->
        %{run | status: :running, started_at: event.recorded_at}
      end)
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_completed, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      invocation
      |> update_run(data["tool_run_id"], fn run ->
        %{run | status: :completed, result: data["result"], completed_at: event.recorded_at}
      end)
      |> release_suspended()
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_failed, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      invocation
      |> update_run(data["tool_run_id"], fn run ->
        %{
          run
          | status: :failed,
            error: data["error"],
            result: data["result"],
            completed_at: event.recorded_at
        }
      end)
      |> release_suspended()
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_interrupted, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      update_run(invocation, data["tool_run_id"], fn run ->
        %{run | status: :interrupted, completed_at: event.recorded_at}
      end)
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :delegation_opened, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      invocation
      |> update_run(data["tool_run_id"], fn run ->
        %{run | child_invocation_id: data["child_invocation_id"]}
      end)
      |> then(&%{&1 | status: :awaiting_delegation})
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :invocation_completed, data: data} = event, state) do
    state
    |> update_invocation(
      data["invocation_id"],
      &%{
        &1
        | status: :completed,
          completion_metadata: data["metadata"]
      }
    )
    |> update_message(data["message_id"], &%{&1 | status: :completed})
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :invocation_failed, data: data} = event, state) do
    error = failure_from_wire!(data["error"])

    state
    |> update_invocation(data["invocation_id"], &%{&1 | status: :failed, error: error})
    |> update_message(data["message_id"], &%{&1 | status: :failed, error: error})
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :invocation_cancelled, data: data} = event, state) do
    failure = Failure.new(:cancelled, data["reason"])

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      %{invocation | status: :cancelled, error: failure, pending_tool_review: nil}
    end)
    |> update_message(data["message_id"], &%{&1 | status: :cancelled, error: failure})
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :turn_completed, data: data} = event, state) do
    outcome = outcome(data["outcome"])

    update_turn(state, data["turn_id"], &%{&1 | status: :terminal, outcome: outcome})
    |> update_room(data["room_id"], fn room ->
      if room.active_turn_id == data["turn_id"] do
        %{room | active_turn_id: nil}
      else
        %{room | queued_turn_ids: List.delete(room.queued_turn_ids, data["turn_id"])}
      end
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_configured, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      run = %SquadRun{
        room_id: turn.room_id,
        workflow_version: data["workflow_version"] || "squad-v1",
        release_authority: release_authority(data["release_authority"]),
        phase_index: 0,
        phase: data["phase"] || "leader_intake",
        cycle: 0,
        rework_count: 0,
        rework_budget: data["rework_budget"],
        role_ids: data["seats"],
        resolutions: [],
        latest_resolution: nil,
        promotions: %{},
        artifacts: [],
        blockers: [],
        retries: [],
        directives: [],
        reviews: [],
        pending_review: nil
      }

      %{turn | squad: run}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_stage_entered, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      squad = %{
        turn.squad
        | phase_index: data["stage"],
          phase: data["phase"] || turn.squad.phase,
          cycle: data["cycle"] || turn.squad.cycle
      }

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_decision_recorded, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      resolution = gate_resolution(data, event.recorded_at, :squad_leader)

      squad = %{
        turn.squad
        | resolutions: [resolution | turn.squad.resolutions],
          latest_resolution: resolution,
          blockers: resolution.reasons
      }

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_artifact_recorded, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      artifact = %Artifact{
        role_id: data["seat_id"],
        kind: data["kind"],
        phase: data["phase"] || turn.squad.phase,
        cycle: data["cycle"] || turn.squad.cycle,
        invocation_id: data["invocation_id"],
        message_id: data["message_id"],
        summary: data["summary"] || "",
        blockers: data["blockers"] || [],
        digest: data["digest"]
      }

      %{
        turn
        | squad: %{
            turn.squad
            | artifacts: [artifact | turn.squad.artifacts],
              blockers: artifact.blockers
          }
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_retry_scheduled, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      retry = %Retry{
        role_id: data["seat_id"],
        attempt: data["attempt"],
        kind: data["kind"] || "provider_retry",
        phase: data["phase"] || turn.squad.phase,
        cycle: data["cycle"] || turn.squad.cycle,
        reason: data["reason"]
      }

      squad = %{turn.squad | retries: [retry | turn.squad.retries]}

      squad =
        if retry.kind == "rework" do
          %{
            squad
            | phase_index: data["target_stage"],
              phase: data["target_phase"],
              cycle: data["cycle"],
              rework_count: squad.rework_count + 1
          }
        else
          squad
        end

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_directive_added, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      directive = %Directive{
        text: data["text"],
        phase: data["phase"],
        cycle: data["cycle"],
        recorded_at: event.recorded_at
      }

      %{turn | squad: %{turn.squad | directives: [directive | turn.squad.directives]}}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :gate_review_requested, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      recommendation = %GateRecommendation{
        role_id: data["seat_id"],
        decision: data["decision"],
        target_phase: data["target_phase"],
        reasons: data["reasons"] || [],
        recommended_at: event.recorded_at
      }

      review = %GateReview{
        id: review_id(data),
        phase: data["phase"],
        cycle: data["cycle"],
        recommendation: recommendation,
        requested_at: event.recorded_at
      }

      squad = %{
        turn.squad
        | reviews: [review | turn.squad.reviews],
          pending_review: review,
          blockers: recommendation.reasons
      }

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :gate_resolved, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      resolution = gate_resolution(data, event.recorded_at, :owner)

      squad = %{
        turn.squad
        | resolutions: [resolution | turn.squad.resolutions],
          latest_resolution: resolution,
          pending_review: nil,
          blockers: resolution.reasons
      }

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_budget_extended, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      %{turn | squad: %{turn.squad | rework_budget: data["budget"]}}
    end)
    |> put_sequence(event.sequence)
  end

  # Old compacted logs can begin with a schema-v2 projection snapshot.
  def apply(%Event{type: :snapshot_recorded, data: %{"binary" => binary}} = event, _state) do
    binary
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
    |> Map.drop([:last_snapshot_sequence])
    |> Map.put(:sequence, event.sequence)
    |> normalize_snapshot()
  end

  # Snapshots written before durable tool runs lack the rounds/tool-run
  # invocation fields; backfill them so recovery code can rely on the shape.
  defp normalize_snapshot(state), do: Projection.from_map(state)

  @doc "Applies a provider frame payload to the projection without advancing the sequence."
  @spec apply_provider_frame(state(), String.t(), map()) :: state()
  def apply_provider_frame(state, invocation_id, frame_data) do
    invocation = state.invocations[invocation_id]

    state =
      if invocation do
        update_invocation(state, invocation_id, fn value ->
          value = %{value | last_frame_sequence: frame_data["frame_sequence"]}
          apply_invocation_frame(value, frame_data["kind"], frame_data["data"])
        end)
      else
        state
      end

    if frame_data["kind"] == "text_delta" && invocation do
      update_message(state, invocation.message_id, fn message ->
        %{message | body: message.body <> frame_data["data"]["text"], status: :streaming}
      end)
    else
      state
    end
  end

  defp opened_message(data, event, participant) do
    %Message{
      id: data["message_id"],
      room_id: data["room_id"],
      turn_id: data["turn_id"],
      invocation_id: data["invocation_id"],
      author: Author.from_participant(participant),
      role: :assistant,
      status: :queued,
      body: "",
      created_at: event.recorded_at,
      created_sequence: event.sequence,
      error: nil
    }
  end

  defp opened_invocation(data, participant) do
    %Invocation{
      id: data["invocation_id"],
      room_id: data["room_id"],
      turn_id: data["turn_id"],
      message_id: data["message_id"],
      participant: participant,
      phase_index: data["stage"],
      phase: value_or(data["phase"], data["label"]),
      cycle: value_or(data["cycle"], 0),
      logical_work_id: value_or(data["logical_work_id"], data["invocation_id"]),
      dependencies: value_or(data["dependencies"], []),
      label: data["label"],
      system_prompt: data["system_prompt"],
      project_instructions: %Capture{
        content: value_or(data["project_instructions"], ""),
        digest: data["project_instruction_digest"],
        sources: value_or(data["project_instruction_sources"], [])
      },
      execution_context: %InvocationExecution{
        output_schema: data["output_schema"],
        workspace: data["workspace"],
        workspace_roots: value_or(data["workspace_roots"], []),
        isolation: data["isolation"]
      },
      status: :queued,
      attempt: value_or(data["attempt"], 1),
      usage: nil,
      tool_events: [],
      rounds: [],
      tool_runs: %{},
      tool_run_order: [],
      pending_tool_review: nil,
      completion_metadata: nil,
      last_frame_sequence: 0,
      error: nil,
      delegation_depth: value_or(data["delegation_depth"], 0),
      delegated_from_invocation_id: data["delegated_from_invocation_id"],
      delegated_from_tool_run_id: data["delegated_from_tool_run_id"]
    }
  end

  defp value_or(nil, default), do: default
  defp value_or(value, _default), do: value

  defp put_message(state, message) do
    update_room(state, message.room_id, fn room ->
      %{room | message_order: [message.id | room.message_order]}
    end)
    |> Map.update!(:messages, &Map.put(&1, message.id, message))
  end

  defp update_run(invocation, run_id, update) do
    Map.update!(invocation, :tool_runs, fn runs ->
      Map.update!(runs, run_id, update)
    end)
  end

  defp resolve_run(run, status, decision),
    do: %{run | status: status, resolution: decision}

  defp awaiting_review(invocation, %{status: :awaiting_approval} = run) do
    if invocation.pending_tool_review do
      invocation
    else
      ask = %ToolAsk{
        request_id: run.id,
        tool: run.tool,
        arguments: run.arguments,
        workspace: run.workspace,
        requested_at: run.requested_at
      }

      %{invocation | status: :waiting_tool_approval, pending_tool_review: ask}
    end
  end

  defp awaiting_review(invocation, _run), do: invocation

  defp clear_review(invocation, run_id, decision) do
    invocation
    |> Map.update(
      :pending_tool_review,
      nil,
      fn
        %{request_id: ^run_id} -> nil
        review -> review
      end
    )
    |> reset_waiting_status(decision)
  end

  # Approving the last pending review returns the invocation to the loop;
  # denial keeps it stopped (the terminal failure event follows immediately).
  defp reset_waiting_status(%{status: :waiting_tool_approval} = invocation, :approve),
    do: %{invocation | status: :running}

  defp reset_waiting_status(invocation, _decision), do: invocation

  defp authorization("allow"), do: :allow
  defp authorization("ask"), do: :ask
  defp authorization("denied"), do: :denied
  defp authorization(value) when is_atom(value), do: value

  defp requested_status("ask"), do: :awaiting_approval
  defp requested_status("denied"), do: :denied
  defp requested_status(_authorization), do: :ready

  # A terminal run on a suspended parent unfreezes it: the child's report is
  # recorded, so the parent re-enters admission as an ordinary queued
  # invocation. This keeps the resume exactly-once and replay-derived.
  defp release_suspended(%{status: :awaiting_delegation} = invocation),
    do: %{invocation | status: :queued}

  defp release_suspended(invocation), do: invocation

  defp decision("approve"), do: :approve
  defp decision("deny"), do: :deny
  defp decision(value) when is_atom(value), do: value

  defp update_room(state, room_id, update) do
    %{state | rooms: Map.update!(state.rooms, room_id, update)}
  end

  defp update_turn(state, turn_id, update) do
    %{state | turns: Map.update!(state.turns, turn_id, update)}
  end

  defp update_invocation(state, invocation_id, update) do
    %{state | invocations: Map.update!(state.invocations, invocation_id, update)}
  end

  defp update_message(state, message_id, update) do
    %{state | messages: Map.update!(state.messages, message_id, update)}
  end

  defp put_sequence(state, sequence), do: %{state | sequence: sequence}

  defp review_id(data), do: "#{data["turn_id"]}:#{data["phase"]}:#{data["cycle"]}"

  defp gate_resolution(data, resolved_at, authority) do
    %GateResolution{
      review_id: review_id(data),
      resolver_id: data["seat_id"],
      authority: authority,
      decision: data["decision"],
      phase: data["phase"],
      cycle: data["cycle"],
      target_phase: data["target_phase"],
      reasons: data["reasons"] || [],
      resolved_at: resolved_at
    }
  end

  defp failure_from_wire!(failure) do
    case Failure.from_wire(failure) do
      {:ok, failure} -> failure
      {:error, :invalid_failure} -> raise ArgumentError, "invalid durable failure"
    end
  end

  defp apply_invocation_frame(invocation, "usage", data) do
    %{invocation | usage: data["usage"]}
  end

  defp apply_invocation_frame(invocation, "agent_note", data) do
    note = data["note"]

    if is_binary(note) and note != "" do
      # Bounded activity trail: a chatty reasoner must not grow the
      # projection without limit; the oldest lines fall off first.
      %{invocation | notes: Enum.take(invocation.notes ++ [note], -@max_invocation_notes)}
    else
      invocation
    end
  end

  defp apply_invocation_frame(invocation, kind, data)
       when kind in ["tool_started", "tool_completed"] do
    %{invocation | tool_events: [Map.put(data, "kind", kind) | invocation.tool_events]}
  end

  # Display frames never drive invocation lifecycle status: a waiting approval
  # stays waiting even while buffered frames are recorded.
  defp apply_invocation_frame(invocation, _kind, _data), do: invocation

  defp participant(data) do
    %Participant{
      id: data["id"],
      name: data["name"],
      perspective: data["perspective"],
      provider: provider(data["provider"]),
      model: data["model"],
      kind: participant_kind(data["kind"])
    }
  end

  defp seat(data) do
    %Seat{
      id: data["id"],
      role_id: data["role_id"] || data["id"],
      name: data["name"],
      perspective: data["perspective"],
      provider: provider(data["provider"]),
      model: data["model"]
    }
  end

  defp release_authority("leader"), do: :squad_leader
  defp release_authority("human"), do: :owner
  defp release_authority(nil), do: :owner

  defp configure_participant(%{id: id} = participant, %{"participant_id" => id} = data) do
    %{participant | provider: provider(data["provider"]), model: data["model"]}
  end

  defp configure_participant(participant, _data), do: participant

  defp participant_kind("primary"), do: :primary
  defp participant_kind(:primary), do: :primary
  defp participant_kind("task"), do: :task
  defp participant_kind(:task), do: :task
  defp participant_kind(_kind), do: :legacy

  # Durable mode values decode with legacy tolerance through the closed
  # contract: retired wire values replay as inert markers so historical
  # turns project cleanly; anything else is impossible validated input and
  # fails at detection.
  defp mode(value) when is_binary(value) do
    case Mode.decode_durable(value) do
      {:ok, mode} -> mode
      {:error, :invalid_mode} -> raise ArgumentError, "invalid durable mode #{inspect(value)}"
    end
  end

  defp mode(value) when is_atom(value) do
    case Mode.decode_durable(value) do
      {:ok, mode} -> mode
      {:error, :invalid_mode} -> raise ArgumentError, "invalid durable mode #{inspect(value)}"
    end
  end

  defp provider(value) when is_binary(value) or is_atom(value),
    do: Registry.normalize_provider_id(value)

  defp input_kind(nil), do: :operator
  defp input_kind("operator"), do: :operator
  defp input_kind("follow_up"), do: :follow_up
  defp input_kind(value) when value in [:operator, :follow_up], do: value

  defp outcome("completed"), do: :completed
  defp outcome("partial"), do: :partial
  defp outcome("failed"), do: :failed
  defp outcome("reworked"), do: :reworked
  defp outcome("cancelled"), do: :cancelled
  defp outcome(value) when is_atom(value), do: value
end
