defmodule ReyCode.Orchestration.EventEntries do
  @moduledoc "Pure construction of orchestration event entries."

  alias ReyCode.Failure

  alias ReyCode.Orchestration.{
    Invocation,
    ModelTier,
    OperatorQuestion,
    Participant,
    Session,
    Squad,
    ToolRun,
    Turn,
    WorkPlan
  }

  alias ReyCode.Orchestration.Squad.Seat
  alias ReyCode.Provider.Frame

  @type event_entry :: {atom(), map(), keyword()}

  @doc "Builds the storage-compatible `room_created` event for one Session."
  @spec session_created(String.t(), String.t(), String.t(), String.t(), [map()]) :: event_entry()
  def session_created(session_id, slug, title, workspace, participants) do
    {
      :room_created,
      %{
        "room_id" => session_id,
        "slug" => slug,
        "title" => title,
        "workspace" => workspace,
        "participants" => Enum.map(participants, &session_participant/1)
      },
      [aggregate_type: :room, aggregate_id: session_id, room_id: session_id]
    }
  end

  @doc "Builds the durable context-compaction boundary for one Session."
  @spec context_compacted(Session.t(), non_neg_integer(), String.t(), map()) :: event_entry()
  def context_compacted(session, through_sequence, summary, metrics) do
    event(
      :context_compacted,
      %{
        "room_id" => session.id,
        "through_sequence" => through_sequence,
        "summary" => summary,
        "source_message_count" => metrics.source_message_count,
        "source_bytes" => metrics.source_bytes,
        "summary_bytes" => byte_size(summary),
        "generator" => "extractive-v1"
      },
      :room,
      session.id,
      session.id,
      session.id
    )
  end

  @doc "Builds the durable parent link and inherited transcript for a forked Session."
  @spec session_forked(String.t(), Session.t(), non_neg_integer(), [String.t()]) ::
          event_entry()
  def session_forked(session_id, parent, through_sequence, inherited_message_ids) do
    event(
      :session_forked,
      %{
        "room_id" => session_id,
        "parent_room_id" => parent.id,
        "through_sequence" => through_sequence,
        "inherited_message_ids" => inherited_message_ids
      },
      :room,
      session_id,
      session_id,
      session_id
    )
  end

  @doc "Builds the event that adds one durable Session Participant."
  @spec participant_added(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          atom(),
          atom(),
          String.t() | nil
        ) ::
          event_entry()
  def participant_added(session_id, participant_id, name, responsibility, kind, provider, model) do
    event(
      :participant_added,
      %{
        "room_id" => session_id,
        "participant_id" => participant_id,
        "name" => name,
        "responsibility" => responsibility,
        "kind" => Atom.to_string(kind),
        "provider" => wire_provider(provider),
        "model" => model
      },
      :room,
      session_id,
      session_id,
      session_id
    )
  end

  @doc "Builds the transcript message recorded for one owner-typed shell command."
  @spec owner_command_posted(String.t(), String.t(), String.t()) :: event_entry()
  def owner_command_posted(session_id, message_id, body) do
    event(
      :message_posted,
      %{
        "message_id" => message_id,
        "room_id" => session_id,
        "turn_id" => nil,
        "author_name" => "You",
        "body" => body
      },
      :room,
      session_id,
      session_id,
      session_id
    )
  end

  @doc "Builds the user-message and queued-turn events for a new turn."
  @spec queue_turn(
          String.t(),
          String.t(),
          atom(),
          String.t(),
          String.t(),
          non_neg_integer(),
          atom(),
          String.t() | nil
        ) :: [event_entry()]
  def queue_turn(
        session_id,
        body,
        mode,
        turn_id,
        message_id,
        context_sequence,
        input_kind,
        participant_id
      ) do
    [
      event(
        :message_posted,
        %{
          "message_id" => message_id,
          "room_id" => session_id,
          "turn_id" => turn_id,
          "author_name" => "You",
          "body" => body
        },
        :room,
        session_id,
        session_id,
        turn_id
      ),
      event(
        :turn_queued,
        %{
          "turn_id" => turn_id,
          "room_id" => session_id,
          "user_message_id" => message_id,
          "mode" => Atom.to_string(mode),
          "context_through_sequence" => context_sequence,
          "input_kind" => Atom.to_string(input_kind),
          "participant_id" => participant_id
        },
        :turn,
        turn_id,
        session_id,
        turn_id
      )
    ]
  end

  @doc "Builds the source message and running-independent Turn for DetachedDelegation."
  @spec detached_turn(
          Invocation.t(),
          Participant.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: [event_entry()]
  def detached_turn(parent, participant, task, turn_id, message_id, context_sequence) do
    [
      event(
        :message_posted,
        %{
          "message_id" => message_id,
          "room_id" => parent.session_id,
          "turn_id" => turn_id,
          "author_name" => parent.participant.name,
          "author_id" => parent.participant.id,
          "author_kind" => "agent",
          "body" => task
        },
        :room,
        parent.session_id,
        parent.session_id,
        turn_id
      ),
      event(
        :turn_queued,
        %{
          "turn_id" => turn_id,
          "room_id" => parent.session_id,
          "user_message_id" => message_id,
          "mode" => "delegate",
          "context_through_sequence" => context_sequence,
          "input_kind" => "detached",
          "participant_id" => participant.id,
          "source_invocation_id" => parent.id,
          "task" => task,
          "detached" => true
        },
        :turn,
        turn_id,
        parent.session_id,
        turn_id
      )
    ]
  end

  @doc "Builds Session Participant configuration events in Participant order."
  @spec participant_configuration(String.t(), [String.t()], atom(), String.t() | nil) ::
          [event_entry()]
  def participant_configuration(session_id, participant_ids, provider, model) do
    Enum.map(participant_ids, fn participant_id ->
      event(
        :participant_configured,
        %{
          "room_id" => session_id,
          "participant_id" => participant_id,
          "provider" => Atom.to_string(provider),
          "model" => model
        },
        :room,
        session_id,
        session_id,
        session_id
      )
    end)
  end

  @doc "Builds one Participant ModelTier configuration event."
  @spec participant_tier_configured(String.t(), String.t(), ModelTier.t()) :: event_entry()
  def participant_tier_configured(session_id, participant_id, tier) do
    event(
      :participant_tier_configured,
      %{
        "room_id" => session_id,
        "participant_id" => participant_id,
        "model_tier" => Atom.to_string(tier)
      },
      :room,
      session_id,
      session_id,
      session_id
    )
  end

  @doc "Builds squad role configuration events in role order."
  @spec squad_role_configuration(String.t(), [String.t()], atom(), String.t() | nil) ::
          [event_entry()]
  def squad_role_configuration(session_id, role_ids, provider, model) do
    Enum.map(role_ids, fn role_id ->
      role = Squad.role(role_id)

      event(
        :squad_role_configured,
        %{
          "room_id" => session_id,
          "role_id" => role.id,
          "name" => role.name,
          "perspective" => role.perspective,
          "provider" => Atom.to_string(provider),
          "model" => model
        },
        :room,
        session_id,
        session_id,
        session_id
      )
    end)
  end

  @doc "Builds the event that marks a turn as running."
  @spec turn_started(Turn.t()) :: event_entry()
  def turn_started(turn) do
    data = %{"turn_id" => turn.id, "room_id" => turn.session_id}
    data = if Map.get(turn, :detached?, false), do: Map.put(data, "detached", true), else: data

    event(
      :turn_started,
      data,
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  @doc "Builds the terminal event for a turn."
  @spec turn_completed(Turn.t(), atom()) :: event_entry()
  def turn_completed(turn, outcome) do
    event(
      :turn_completed,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.session_id,
        "outcome" => Atom.to_string(outcome)
      },
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  @doc "Builds the invocation and turn events required to cancel a turn."
  @spec cancel_turn(Turn.t(), [Invocation.t()], String.t()) :: [event_entry()]
  def cancel_turn(turn, invocations, reason) do
    turn_entry =
      event(
        :turn_completed,
        %{"turn_id" => turn.id, "room_id" => turn.session_id, "outcome" => "cancelled"},
        :turn,
        turn.id,
        turn.session_id,
        turn.id
      )

    cancel_invocations(invocations, reason) ++ [turn_entry]
  end

  @doc "Builds cancellation events for active invocations without completing their turn."
  @spec cancel_invocations([Invocation.t()], String.t()) :: [event_entry()]
  def cancel_invocations(invocations, reason) do
    Enum.map(invocations, fn invocation ->
      invocation_event(
        :invocation_cancelled,
        %{
          "invocation_id" => invocation.id,
          "message_id" => invocation.message_id,
          "turn_id" => invocation.turn_id,
          "room_id" => invocation.session_id,
          "reason" => reason
        },
        invocation
      )
    end)
  end

  @doc "Builds the event that marks a queued invocation as running."
  @spec invocation_started(Invocation.t()) :: event_entry()
  def invocation_started(invocation) do
    invocation_event(
      :invocation_started,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id
      },
      invocation
    )
  end

  @doc "Builds one durable Operator steering request for an active Invocation."
  @spec invocation_steering_requested(Invocation.t(), String.t(), String.t()) :: event_entry()
  def invocation_steering_requested(invocation, steering_id, body) do
    invocation_event(
      :invocation_steering_requested,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "steering_id" => steering_id,
        "body" => body
      },
      invocation
    )
  end

  @doc "Builds the durable event for a validated provider frame."
  @spec provider_frame(Invocation.t(), Frame.t()) :: event_entry()
  def provider_frame(invocation, frame) do
    data =
      Map.merge(Frame.to_event_data(frame), %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id
      })

    invocation_event(:provider_frame_recorded, data, invocation)
  end

  @doc "Builds an operator directive event for a running squad turn."
  @spec squad_directive(Turn.t(), String.t()) :: event_entry()
  def squad_directive(turn, directive) do
    event(
      :squad_directive_added,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.session_id,
        "text" => directive,
        "phase" => turn.squad.phase,
        "cycle" => turn.squad.cycle
      },
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  @doc "Builds the event recording a human gate decision."
  @spec gate_resolved(Turn.t(), map(), atom(), String.t() | nil, [String.t()]) ::
          event_entry()
  def gate_resolved(turn, review, decision, target_phase, reasons) do
    event(
      :gate_resolved,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.session_id,
        "seat_id" => "human_owner",
        "decision" => Atom.to_string(decision),
        "phase" => review.phase,
        "cycle" => review.cycle,
        "target_phase" => target_phase,
        "reasons" => reasons
      },
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  @doc "Builds the durable event for one normalized provider round."
  @spec provider_round(Invocation.t(), non_neg_integer(), map()) :: event_entry()
  def provider_round(invocation, round_index, round_data) do
    invocation_event(
      :provider_round_recorded,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "round_index" => round_index,
        "text" => round_data["text"],
        "tool_calls" => round_data["tool_calls"],
        "usage" => round_data["usage"],
        "steering" => Map.get(round_data, "steering", [])
      },
      invocation
    )
  end

  @doc "Builds the durable event requesting one tool run under an authorization decision."
  @spec tool_run_requested(Invocation.t(), ToolRun.t()) :: event_entry()
  def tool_run_requested(invocation, run) do
    invocation_event(
      :tool_run_requested,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "tool_run_id" => run.id,
        "tool_call_id" => run.tool_call_id,
        "round_index" => run.round_index,
        "tool" => run.tool,
        "arguments" => run.arguments,
        "workspace" => run.workspace,
        "workspace_roots" => run.workspace_roots,
        "authorization" => Atom.to_string(run.authorization)
      },
      invocation
    )
  end

  @doc "Builds the durable event recording the owner decision for a tool run."
  @spec tool_run_approval_resolved(Invocation.t(), ToolRun.t(), atom()) :: event_entry()
  def tool_run_approval_resolved(invocation, run, decision) do
    invocation_event(
      :tool_run_approval_resolved,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "tool_run_id" => run.id,
        "tool" => run.tool,
        "decision" => Atom.to_string(decision)
      },
      invocation
    )
  end

  @doc "Builds the durable event marking a tool run as executing."
  @spec tool_run_started(Invocation.t(), ToolRun.t()) :: event_entry()
  def tool_run_started(invocation, run) do
    invocation_event(
      :tool_run_started,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "tool_run_id" => run.id,
        "tool" => run.tool
      },
      invocation
    )
  end

  @doc "Builds the durable event recording a successful tool run result."
  @spec tool_run_completed(Invocation.t(), ToolRun.t(), map()) :: event_entry()
  def tool_run_completed(invocation, run, result) do
    invocation_event(
      :tool_run_completed,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "tool_run_id" => run.id,
        "tool" => run.tool,
        "result" => result
      },
      invocation
    )
  end

  @doc "Builds the durable event recording a tool run failure outcome."
  @spec tool_run_failed(Invocation.t(), ToolRun.t(), map()) :: event_entry()
  def tool_run_failed(invocation, run, error) do
    invocation_event(
      :tool_run_failed,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "tool_run_id" => run.id,
        "tool" => run.tool,
        "error" => error,
        "result" => error
      },
      invocation
    )
  end

  @doc "Builds the durable event recording an interrupted (indeterminate) tool run."
  @spec tool_run_interrupted(Invocation.t(), ToolRun.t(), String.t()) :: event_entry()
  def tool_run_interrupted(invocation, run, reason) do
    invocation_event(
      :tool_run_interrupted,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "tool_run_id" => run.id,
        "tool" => run.tool,
        "reason" => reason
      },
      invocation
    )
  end

  @doc """
  Builds the event linking one parent `spawn_task` tool run to its child
  invocation and durably suspending the parent until the child terminates.
  """
  @spec delegation_opened(
          Invocation.t(),
          ToolRun.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          boolean()
        ) :: event_entry()
  def delegation_opened(
        parent_invocation,
        run,
        child_invocation_id,
        child_message_id,
        depth,
        suspend_parent \\ true
      ) do
    invocation_event(
      :delegation_opened,
      %{
        "invocation_id" => parent_invocation.id,
        "message_id" => parent_invocation.message_id,
        "turn_id" => parent_invocation.turn_id,
        "room_id" => parent_invocation.session_id,
        "tool_run_id" => run.id,
        "child_invocation_id" => child_invocation_id,
        "child_message_id" => child_message_id,
        "delegation_depth" => depth,
        "suspend_parent" => suspend_parent
      },
      parent_invocation
    )
  end

  @doc "Builds the owner merge-review request for one isolated delegated child."
  @spec delegation_merge_requested(Invocation.t(), Invocation.t(), ToolRun.t(), String.t()) ::
          event_entry()
  def delegation_merge_requested(child, parent, run, diff) do
    isolation = child.execution_context.isolation

    invocation_event(
      :delegation_merge_requested,
      %{
        "invocation_id" => child.id,
        "message_id" => child.message_id,
        "turn_id" => child.turn_id,
        "room_id" => child.session_id,
        "parent_invocation_id" => parent.id,
        "tool_run_id" => run.id,
        "diff" => diff,
        "workspace" => isolation["workspace"],
        "source_workspace" => isolation["source_workspace"]
      },
      child
    )
  end

  @doc "Builds the durable owner decision for one isolated delegated child."
  @spec delegation_merge_resolved(Invocation.t(), ToolRun.t(), atom()) :: event_entry()
  def delegation_merge_resolved(child, run, decision) do
    invocation_event(
      :delegation_merge_resolved,
      %{
        "invocation_id" => child.id,
        "message_id" => child.message_id,
        "turn_id" => child.turn_id,
        "room_id" => child.session_id,
        "tool_run_id" => run.id,
        "decision" => Atom.to_string(decision)
      },
      child
    )
  end

  @doc "Builds one durable PeerMessage delivery event."
  @spec peer_message_sent(
          Invocation.t(),
          Invocation.t(),
          String.t(),
          String.t()
        ) :: event_entry()
  def peer_message_sent(sender, target, peer_message_id, body) do
    invocation_event(
      :peer_message_sent,
      %{
        "turn_id" => sender.turn_id,
        "room_id" => sender.session_id,
        "peer_message_id" => peer_message_id,
        "sender_invocation_id" => sender.id,
        "sender_name" => sender.participant.name,
        "target_invocation_id" => target.id,
        "body" => body
      },
      sender
    )
  end

  @doc "Builds the event that pauses an Invocation for one OperatorQuestion."
  @spec operator_question_asked(Invocation.t(), OperatorQuestion.t()) :: event_entry()
  def operator_question_asked(invocation, question) do
    invocation_event(
      :operator_question_asked,
      Map.merge(
        %{
          "invocation_id" => invocation.id,
          "message_id" => invocation.message_id,
          "turn_id" => invocation.turn_id,
          "room_id" => invocation.session_id
        },
        OperatorQuestion.to_wire(question)
      ),
      invocation
    )
  end

  @doc "Builds the event recording one validated Operator answer."
  @spec operator_question_answered(
          Invocation.t(),
          OperatorQuestion.t(),
          map()
        ) :: event_entry()
  def operator_question_answered(invocation, question, answer) do
    {selected_id, selected_label} = legacy_selection(question, answer)

    invocation_event(
      :operator_question_answered,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "question_id" => question.id,
        "tool_run_id" => question.tool_run_id,
        "selected_id" => selected_id,
        "selected_label" => selected_label,
        "selected_ids" => answer.option_ids,
        "selected_labels" => answer.labels,
        "other" => answer.other
      },
      invocation
    )
  end

  @doc "Builds one complete validated WorkPlan projection event."
  @spec invocation_plan_updated(Invocation.t(), WorkPlan.t()) :: event_entry()
  def invocation_plan_updated(invocation, plan) do
    invocation_event(
      :invocation_plan_updated,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "plan" => WorkPlan.to_wire(plan)
      },
      invocation
    )
  end

  @doc "Builds the event durably extending a squad turn's rework budget."
  @spec squad_budget_extended(Turn.t(), pos_integer()) :: event_entry()
  def squad_budget_extended(turn, budget) do
    event(
      :squad_budget_extended,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.session_id,
        "budget" => budget
      },
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  @doc """
  Builds the gate event recording one squad role's structured gate output.

  The type is release policy decided by the squad finalizer: a human-owned
  release gate records `:gate_review_requested`, everything else records an
  automated `:squad_decision_recorded`.
  """
  @spec squad_gate(Invocation.t(), map(), :gate_review_requested | :squad_decision_recorded) ::
          event_entry()
  def squad_gate(invocation, output, type) do
    data = %{
      "turn_id" => invocation.turn_id,
      "room_id" => invocation.session_id,
      "seat_id" => invocation.participant.id,
      "decision" => output["decision"],
      "phase" => invocation.phase,
      "cycle" => invocation.cycle,
      "target_phase" => output["target_phase"],
      "reasons" => output["reasons"]
    }

    event(type, data, :turn, invocation.turn_id, invocation.session_id, invocation.turn_id)
  end

  @doc "Builds the event recording one squad role's structured artifact output."
  @spec squad_artifact(Invocation.t(), map(), String.t()) :: event_entry()
  def squad_artifact(invocation, output, digest) do
    data = %{
      "turn_id" => invocation.turn_id,
      "room_id" => invocation.session_id,
      "seat_id" => invocation.participant.id,
      "kind" => output["artifact_type"],
      "phase" => invocation.phase,
      "cycle" => invocation.cycle,
      "invocation_id" => invocation.id,
      "message_id" => invocation.message_id,
      "summary" => output["summary"],
      "blockers" => output["blockers"],
      "digest" => digest
    }

    {:squad_artifact_recorded, data,
     aggregate_metadata(:turn, invocation.turn_id, invocation.session_id, invocation.turn_id)}
  end

  @doc "Builds the configuration and initial-stage events for a squad turn."
  @spec squad_start(Turn.t(), keyword()) :: [event_entry()]
  def squad_start(turn, config) do
    metadata = aggregate_metadata(:turn, turn.id, turn.session_id, turn.id)

    [
      {
        :squad_configured,
        %{
          "turn_id" => turn.id,
          "room_id" => turn.session_id,
          "seats" => Enum.map(Squad.roles(), & &1.id),
          "rework_budget" => Keyword.fetch!(config, :rework_budget),
          "release_authority" =>
            wire_release_authority(Keyword.fetch!(config, :release_authority)),
          "workflow_version" => Squad.workflow_version(),
          "phase" => Squad.phase_label(0)
        },
        metadata
      },
      {
        :squad_stage_entered,
        %{
          "turn_id" => turn.id,
          "room_id" => turn.session_id,
          "stage" => 0,
          "phase" => Squad.phase_label(0),
          "cycle" => 0
        },
        metadata
      }
    ]
  end

  @doc "Builds the stage or rework event needed before the next squad invocations."
  @spec squad_continue(Turn.t(), [map()]) :: [event_entry()]
  def squad_continue(_turn, []), do: []

  def squad_continue(turn, [spec | _specs]) do
    cond do
      spec.cycle > turn.squad.cycle ->
        [squad_rework_entry(turn, spec)]

      spec.phase_index != turn.squad.phase_index ->
        [squad_stage_entry(turn, spec)]

      true ->
        []
    end
  end

  @doc "Builds assistant-message events that establish planned provider invocations."
  @spec open_invocations(Session.t(), Turn.t(), [map()], [{String.t(), String.t()}]) ::
          [event_entry()]
  def open_invocations(session, turn, specs, generated_ids) do
    if length(specs) != length(generated_ids) do
      raise ArgumentError,
            "expected one generated ID pair per invocation spec, got #{length(specs)} specs and #{length(generated_ids)} ID pairs"
    end

    specs
    |> Enum.zip(generated_ids)
    |> Enum.map(&open_invocation_entry(session, turn, &1))
  end

  @doc "Builds an event entry correlated to an Invocation's Turn and Session."
  @spec invocation_event(atom(), map(), Invocation.t()) :: event_entry()
  def invocation_event(type, data, invocation) do
    event(
      type,
      data,
      :invocation,
      invocation.id,
      invocation.session_id,
      invocation.turn_id
    )
  end

  @doc "Builds the terminal event for a completed or failed invocation."
  @spec invocation_terminal(Invocation.t(), {:completed, map()} | {:failed, Failure.t()}) ::
          event_entry()
  def invocation_terminal(invocation, {:completed, metadata}) do
    invocation_event(
      :invocation_completed,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "metadata" => metadata
      },
      invocation
    )
  end

  def invocation_terminal(invocation, {:failed, error}) do
    invocation_event(
      :invocation_failed,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "error" => Failure.to_wire(error)
      },
      invocation
    )
  end

  @doc "Builds the durable event that schedules another squad provider attempt."
  @spec squad_provider_retry(Invocation.t(), Failure.t()) :: event_entry()
  def squad_provider_retry(invocation, %Failure{} = error) do
    event(
      :squad_retry_scheduled,
      %{
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.session_id,
        "seat_id" => invocation.participant.id,
        "attempt" => invocation.attempt + 1,
        "kind" => "provider_retry",
        "phase" => invocation.phase,
        "cycle" => invocation.cycle,
        "reason" => Atom.to_string(error.category)
      },
      :turn,
      invocation.turn_id,
      invocation.session_id,
      invocation.turn_id
    )
  end

  @doc "Builds the aggregate and correlation metadata required by durable events."
  @spec aggregate_metadata(atom(), String.t(), String.t(), String.t()) :: keyword()
  def aggregate_metadata(type, aggregate_id, session_id, correlation_id) do
    [
      aggregate_type: type,
      aggregate_id: aggregate_id,
      room_id: session_id,
      correlation_id: correlation_id
    ]
  end

  defp event(type, data, aggregate_type, aggregate_id, session_id, correlation_id) do
    {
      type,
      data,
      aggregate_metadata(aggregate_type, aggregate_id, session_id, correlation_id)
    }
  end

  defp squad_rework_entry(turn, spec) do
    event(
      :squad_retry_scheduled,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.session_id,
        "seat_id" => "squad_leader",
        "attempt" => turn.squad.rework_count + 1,
        "kind" => "rework",
        "phase" => turn.squad.phase,
        "target_stage" => spec.phase_index,
        "target_phase" => spec.phase,
        "cycle" => spec.cycle,
        "reason" => "leader_requested_rework"
      },
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  defp squad_stage_entry(turn, spec) do
    event(
      :squad_stage_entered,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.session_id,
        "stage" => spec.phase_index,
        "phase" => spec.phase,
        "cycle" => spec.cycle
      },
      :turn,
      turn.id,
      turn.session_id,
      turn.id
    )
  end

  defp open_invocation_entry(session, turn, {spec, {invocation_id, message_id}}) do
    participant =
      Enum.find(session.participants, &(&1.id == spec.participant_id)) ||
        Map.get(spec, :participant)

    model_tier = Map.get(spec, :model_tier, Map.get(participant, :model_tier, :default))

    token_budget_tokens =
      Map.get(spec, :token_budget_tokens, ModelTier.budget_tokens(model_tier))

    invocation_event(
      :assistant_message_opened,
      %{
        "invocation_id" => invocation_id,
        "message_id" => message_id,
        "turn_id" => turn.id,
        "room_id" => session.id,
        "participant" => wire_participant(participant),
        "stage" => spec.phase_index,
        "phase" => Map.get(spec, :phase, spec.label),
        "cycle" => Map.get(spec, :cycle, 0),
        "logical_work_id" => Map.get(spec, :logical_work_id, invocation_id),
        "dependencies" => Map.get(spec, :dependencies, []),
        "label" => spec.label,
        "system_prompt" => spec.system_prompt,
        "project_instructions" => Map.get(spec, :project_instructions, ""),
        "project_instruction_digest" => Map.get(spec, :project_instruction_digest),
        "project_instruction_sources" => Map.get(spec, :project_instruction_sources, []),
        "attempt" => Map.get(spec, :attempt, 1),
        "model_tier" => Atom.to_string(model_tier),
        "token_budget_tokens" => token_budget_tokens,
        "output_schema" => Map.get(spec, :output_schema),
        "workspace" => Map.get(spec, :workspace) || Map.get(session, :workspace) || "",
        "workspace_roots" => Map.get(spec, :workspace_roots, []),
        "isolation" => Map.get(spec, :isolation)
      }
      |> Map.merge(delegation_origin(spec)),
      %Invocation{
        id: invocation_id,
        session_id: session.id,
        turn_id: turn.id
      }
    )
  end

  # Delegation origin keys are optional with strict :id rules; they are only
  # emitted for agent-initiated delegation children, never as nils.
  defp delegation_origin(spec) do
    spec
    |> Map.take([:delegated_from_invocation_id, :delegated_from_tool_run_id])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> then(fn merged ->
      case Map.get(spec, :delegation_depth) do
        nil -> merged
        depth -> Map.put(merged, "delegation_depth", depth)
      end
    end)
  end

  defp session_participant(%Participant{} = participant), do: wire_participant(participant)
  defp session_participant(participant) when is_map(participant), do: participant

  defp wire_participant(%Seat{} = seat) do
    seat
    |> Map.from_struct()
    |> wire_participant()
    |> Map.put("role_id", seat.role_id)
  end

  defp wire_participant(participant) do
    %{
      "id" => participant.id,
      "name" => participant.name,
      "perspective" => participant.perspective,
      "provider" => wire_provider(participant.provider),
      "model" => participant.model,
      "model_tier" => Atom.to_string(Map.get(participant, :model_tier, :default)),
      "kind" => wire_kind(Map.get(participant, :kind))
    }
  end

  defp legacy_selection(_question, %{option_ids: [], other: other}), do: {"other", other}

  defp legacy_selection(_question, answer) do
    {List.first(answer.option_ids), Enum.join(answer.labels, ", ")}
  end

  defp wire_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp wire_provider(provider), do: provider

  defp wire_kind(kind) when kind in [:primary, :task], do: Atom.to_string(kind)
  defp wire_kind(_kind), do: "legacy"

  defp wire_release_authority(:owner), do: "human"
  defp wire_release_authority(:squad_leader), do: "leader"
end
