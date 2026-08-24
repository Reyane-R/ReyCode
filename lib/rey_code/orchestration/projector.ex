defmodule ReyCode.Orchestration.Projector do
  @moduledoc "Pure projection of room orchestration events."

  import Kernel, except: [apply: 2]

  alias ReyCode.Event

  alias ReyCode.Orchestration.{
    Invocation,
    Message,
    Participant,
    Projection,
    Room,
    ToolRun,
    Turn
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
      squad_roles: %{},
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
      role = %{
        id: data["role_id"],
        name: data["name"],
        perspective: data["perspective"],
        provider: provider(data["provider"]),
        model: data["model"]
      }

      %{room | squad_roles: Map.put(room.squad_roles, role.id, role)}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :message_posted, data: data} = event, state) do
    message = %Message{
      id: data["message_id"],
      room_id: data["room_id"],
      turn_id: data["turn_id"],
      invocation_id: nil,
      author: %{kind: :user, id: "user", name: data["author_name"] || "You"},
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
      mode: mode(data["mode"]),
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
    participant = participant(data["participant"])

    message = %Message{
      id: data["message_id"],
      room_id: data["room_id"],
      turn_id: data["turn_id"],
      invocation_id: data["invocation_id"],
      author: %{kind: :agent, id: participant.id, name: participant.name},
      role: :assistant,
      status: :queued,
      body: "",
      created_at: event.recorded_at,
      created_sequence: event.sequence,
      error: nil
    }

    invocation = %Invocation{
      id: data["invocation_id"],
      room_id: data["room_id"],
      turn_id: data["turn_id"],
      message_id: data["message_id"],
      participant: participant,
      stage: data["stage"],
      phase: data["phase"] || data["label"],
      cycle: data["cycle"] || 0,
      logical_work_id: data["logical_work_id"] || data["invocation_id"],
      dependencies: data["dependencies"] || [],
      label: data["label"],
      system_prompt: data["system_prompt"],
      status: :queued,
      attempt: data["attempt"] || 1,
      usage: nil,
      tool_events: [],
      rounds: [],
      tool_runs: %{},
      tool_run_order: [],
      pending_tool_review: nil,
      completion_metadata: nil,
      last_frame_sequence: 0,
      error: nil
    }

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

  def apply(%Event{type: :tool_ask_requested, data: data} = event, state) do
    review = %{
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
          do: %{
            "category" => "tool_denied",
            "message" => "Tool request denied",
            "retryable" => false
          },
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
    round = %{
      index: data["round_index"],
      text: data["text"],
      tool_calls: data["tool_calls"],
      usage: data["usage"]
    }

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      %{
        invocation
        | rounds: invocation.rounds ++ [round],
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
      update_run(invocation, data["tool_run_id"], fn run ->
        %{run | status: :completed, result: data["result"], completed_at: event.recorded_at}
      end)
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :tool_run_failed, data: data} = event, state) do
    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      update_run(invocation, data["tool_run_id"], fn run ->
        %{
          run
          | status: :failed,
            error: data["error"],
            result: data["result"],
            completed_at: event.recorded_at
        }
      end)
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
    error = data["error"]

    state
    |> update_invocation(data["invocation_id"], &%{&1 | status: :failed, error: error})
    |> update_message(data["message_id"], &%{&1 | status: :failed, error: error})
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :invocation_cancelled, data: data} = event, state) do
    reason = %{"category" => "cancelled", "message" => data["reason"], "retryable" => false}

    state
    |> update_invocation(data["invocation_id"], fn invocation ->
      %{invocation | status: :cancelled, error: reason, pending_tool_review: nil}
    end)
    |> update_message(data["message_id"], &%{&1 | status: :cancelled, error: reason})
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :turn_completed, data: data} = event, state) do
    outcome = outcome(data["outcome"])

    update_turn(state, data["turn_id"], &%{&1 | status: outcome, outcome: outcome})
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
      %{
        turn
        | squad: %{
            room_id: turn.room_id,
            workflow_version: data["workflow_version"] || "squad-v1",
            release_authority: data["release_authority"] || "human",
            stage: 0,
            phase: data["phase"] || "leader_intake",
            cycle: 0,
            rework_count: 0,
            rework_budget: data["rework_budget"],
            seats: data["seats"],
            decisions: [],
            latest_gate: nil,
            promotions: %{},
            artifacts: [],
            blockers: [],
            retries: [],
            directives: [],
            gate_reviews: [],
            pending_review: nil
          }
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_stage_entered, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      squad = %{
        turn.squad
        | stage: data["stage"],
          phase: data["phase"] || turn.squad.phase,
          cycle: data["cycle"] || turn.squad.cycle
      }

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_decision_recorded, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      decision = %{
        role_id: data["seat_id"],
        decision: data["decision"],
        phase: data["phase"] || turn.squad.phase,
        cycle: data["cycle"] || turn.squad.cycle,
        target_phase: data["target_phase"],
        reasons: data["reasons"] || []
      }

      %{
        turn
        | squad: %{
            turn.squad
            | decisions: [decision | turn.squad.decisions],
              latest_gate: decision,
              blockers: decision.reasons
          }
      }
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_artifact_recorded, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      artifact = %{
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
      retry = %{
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
            | stage: data["target_stage"],
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
      directive = %{
        text: data["text"],
        phase: data["phase"],
        cycle: data["cycle"],
        recorded_at: event.recorded_at
      }

      directives = [directive | Map.get(turn.squad, :directives, [])]
      %{turn | squad: Map.put(turn.squad, :directives, directives)}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :gate_review_requested, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      review = gate_decision(data, event.recorded_at, "agent")
      reviews = [review | Map.get(turn.squad, :gate_reviews, [])]

      squad =
        turn.squad
        |> Map.put(:gate_reviews, reviews)
        |> Map.put(:pending_review, review)
        |> Map.put(:blockers, review.reasons)

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :gate_resolved, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      decision = gate_decision(data, event.recorded_at, "human")
      decisions = [decision | turn.squad.decisions]

      squad =
        turn.squad
        |> Map.put(:decisions, decisions)
        |> Map.put(:latest_gate, decision)
        |> Map.put(:pending_review, nil)
        |> Map.put(:blockers, decision.reasons)

      %{turn | squad: squad}
    end)
    |> put_sequence(event.sequence)
  end

  def apply(%Event{type: :squad_budget_extended, data: data} = event, state) do
    update_turn(state, data["turn_id"], fn turn ->
      %{turn | squad: Map.put(turn.squad, :rework_budget, data["budget"])}
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
      %{
        invocation
        | status: :waiting_tool_approval,
          pending_tool_review: %{
            request_id: run.id,
            tool: run.tool,
            arguments: run.arguments,
            workspace: run.workspace,
            requested_at: run.requested_at
          }
      }
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

  # The review id is derived from the gate's coordinates so replays of old
  # events synthesize the same identity the TUI captured when it opened.
  defp gate_decision(data, recorded_at, actor) do
    %{
      review_id: "#{data["turn_id"]}:#{data["phase"]}:#{data["cycle"]}",
      role_id: data["seat_id"],
      decision: data["decision"],
      phase: data["phase"],
      cycle: data["cycle"],
      target_phase: data["target_phase"],
      reasons: data["reasons"] || [],
      actor: actor,
      recorded_at: recorded_at
    }
  end

  defp apply_invocation_frame(invocation, "usage", data) do
    %{invocation | usage: data["usage"]}
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
      model: data["model"]
    }
  end

  defp configure_participant(%{id: id} = participant, %{"participant_id" => id} = data) do
    %{participant | provider: provider(data["provider"]), model: data["model"]}
  end

  defp configure_participant(participant, _data), do: participant

  defp mode("compare"), do: :compare
  defp mode("debate"), do: :debate
  defp mode("fan_out"), do: :fan_out
  defp mode("squad"), do: :squad
  defp mode(value) when is_atom(value), do: value

  defp provider(value) when is_binary(value) or is_atom(value),
    do: Registry.normalize_provider_id(value)

  defp outcome("completed"), do: :completed
  defp outcome("partial"), do: :partial
  defp outcome("failed"), do: :failed
  defp outcome("reworked"), do: :reworked
  defp outcome("cancelled"), do: :cancelled
  defp outcome(value) when is_atom(value), do: value
end
