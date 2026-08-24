defmodule ReyCode.Orchestration.EventEntries do
  @moduledoc "Pure construction of orchestration event entries."

  alias ReyCode.Orchestration.{Invocation, Room, Squad, ToolRun, Turn}
  alias ReyCode.Provider.Frame

  @type event_entry :: {atom(), map(), keyword()}

  @doc "Builds the event that creates a room."
  @spec room_created(String.t(), String.t(), String.t(), String.t(), [map()]) :: event_entry()
  def room_created(room_id, slug, title, workspace, participants) do
    {
      :room_created,
      %{
        "room_id" => room_id,
        "slug" => slug,
        "title" => title,
        "workspace" => workspace,
        "participants" => participants
      },
      [aggregate_type: :room, aggregate_id: room_id, room_id: room_id]
    }
  end

  @doc "Builds the user-message and queued-turn events for a new turn."
  @spec queue_turn(String.t(), String.t(), atom(), String.t(), String.t(), non_neg_integer()) ::
          [event_entry()]
  def queue_turn(room_id, body, mode, turn_id, message_id, context_sequence) do
    [
      event(
        :message_posted,
        %{
          "message_id" => message_id,
          "room_id" => room_id,
          "turn_id" => turn_id,
          "author_name" => "You",
          "body" => body
        },
        :room,
        room_id,
        room_id,
        turn_id
      ),
      event(
        :turn_queued,
        %{
          "turn_id" => turn_id,
          "room_id" => room_id,
          "user_message_id" => message_id,
          "mode" => Atom.to_string(mode),
          "context_through_sequence" => context_sequence
        },
        :turn,
        turn_id,
        room_id,
        turn_id
      )
    ]
  end

  @doc "Builds room participant configuration events in participant order."
  @spec participant_configuration(String.t(), [String.t()], atom(), String.t() | nil) ::
          [event_entry()]
  def participant_configuration(room_id, participant_ids, provider, model) do
    Enum.map(participant_ids, fn participant_id ->
      event(
        :participant_configured,
        %{
          "room_id" => room_id,
          "participant_id" => participant_id,
          "provider" => Atom.to_string(provider),
          "model" => model
        },
        :room,
        room_id,
        room_id,
        room_id
      )
    end)
  end

  @doc "Builds squad role configuration events in role order."
  @spec squad_role_configuration(String.t(), [String.t()], atom(), String.t() | nil) ::
          [event_entry()]
  def squad_role_configuration(room_id, role_ids, provider, model) do
    Enum.map(role_ids, fn role_id ->
      role = Squad.role(role_id)

      event(
        :squad_role_configured,
        %{
          "room_id" => room_id,
          "role_id" => role.id,
          "name" => role.name,
          "perspective" => role.perspective,
          "provider" => Atom.to_string(provider),
          "model" => model
        },
        :room,
        room_id,
        room_id,
        room_id
      )
    end)
  end

  @doc "Builds the event that marks a turn as running."
  @spec turn_started(Turn.t()) :: event_entry()
  def turn_started(turn) do
    event(
      :turn_started,
      %{"turn_id" => turn.id, "room_id" => turn.room_id},
      :turn,
      turn.id,
      turn.room_id,
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
        "room_id" => turn.room_id,
        "outcome" => Atom.to_string(outcome)
      },
      :turn,
      turn.id,
      turn.room_id,
      turn.id
    )
  end

  @doc "Builds the invocation and turn events required to cancel a turn."
  @spec cancel_turn(Turn.t(), [Invocation.t()], String.t()) :: [event_entry()]
  def cancel_turn(turn, invocations, reason) do
    turn_entry =
      event(
        :turn_completed,
        %{"turn_id" => turn.id, "room_id" => turn.room_id, "outcome" => "cancelled"},
        :turn,
        turn.id,
        turn.room_id,
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
          "room_id" => invocation.room_id,
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
        "room_id" => invocation.room_id
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
        "room_id" => invocation.room_id
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
        "room_id" => turn.room_id,
        "text" => directive,
        "phase" => turn.squad.phase,
        "cycle" => turn.squad.cycle
      },
      :turn,
      turn.id,
      turn.room_id,
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
        "room_id" => turn.room_id,
        "seat_id" => "human_owner",
        "decision" => Atom.to_string(decision),
        "phase" => review.phase,
        "cycle" => review.cycle,
        "target_phase" => target_phase,
        "reasons" => reasons
      },
      :turn,
      turn.id,
      turn.room_id,
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
        "room_id" => invocation.room_id,
        "round_index" => round_index,
        "text" => round_data["text"],
        "tool_calls" => round_data["tool_calls"],
        "usage" => round_data["usage"]
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
        "room_id" => invocation.room_id,
        "tool_run_id" => run.id,
        "tool_call_id" => run.tool_call_id,
        "round_index" => run.round_index,
        "tool" => run.tool,
        "arguments" => run.arguments,
        "workspace" => run.workspace,
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
        "room_id" => invocation.room_id,
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
        "room_id" => invocation.room_id,
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
        "room_id" => invocation.room_id,
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
        "room_id" => invocation.room_id,
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
        "room_id" => invocation.room_id,
        "tool_run_id" => run.id,
        "tool" => run.tool,
        "reason" => reason
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
        "room_id" => turn.room_id,
        "budget" => budget
      },
      :turn,
      turn.id,
      turn.room_id,
      turn.id
    )
  end

  @doc "Builds the configuration and initial-stage events for a squad turn."
  @spec squad_start(Turn.t(), keyword()) :: [event_entry()]
  def squad_start(turn, config) do
    metadata = aggregate_metadata(:turn, turn.id, turn.room_id, turn.id)

    [
      {
        :squad_configured,
        %{
          "turn_id" => turn.id,
          "room_id" => turn.room_id,
          "seats" => Enum.map(Squad.roles(), & &1.id),
          "rework_budget" => Keyword.fetch!(config, :rework_budget),
          "release_authority" => Keyword.fetch!(config, :release_authority),
          "workflow_version" => Squad.workflow_version(),
          "phase" => Squad.stage_label(0)
        },
        metadata
      },
      {
        :squad_stage_entered,
        %{
          "turn_id" => turn.id,
          "room_id" => turn.room_id,
          "stage" => 0,
          "phase" => Squad.stage_label(0),
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

      spec.stage != turn.squad.stage ->
        [squad_stage_entry(turn, spec)]

      true ->
        []
    end
  end

  @doc "Builds assistant-message events that establish planned provider invocations."
  @spec open_invocations(Room.t(), Turn.t(), [map()], [{String.t(), String.t()}]) ::
          [event_entry()]
  def open_invocations(room, turn, specs, generated_ids) do
    if length(specs) != length(generated_ids) do
      raise ArgumentError,
            "expected one generated ID pair per invocation spec, got #{length(specs)} specs and #{length(generated_ids)} ID pairs"
    end

    specs
    |> Enum.zip(generated_ids)
    |> Enum.map(&open_invocation_entry(room, turn, &1))
  end

  @doc "Builds an event entry correlated to an invocation's turn and room."
  @spec invocation_event(atom(), map(), Invocation.t()) :: event_entry()
  def invocation_event(type, data, invocation) do
    event(
      type,
      data,
      :invocation,
      invocation.id,
      invocation.room_id,
      invocation.turn_id
    )
  end

  @doc "Builds the terminal event for a completed or failed invocation."
  @spec invocation_terminal(Invocation.t(), {:completed, map()} | {:failed, map()}) ::
          event_entry()
  def invocation_terminal(invocation, {:completed, metadata}) do
    invocation_event(
      :invocation_completed,
      %{
        "invocation_id" => invocation.id,
        "message_id" => invocation.message_id,
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.room_id,
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
        "room_id" => invocation.room_id,
        "error" => error
      },
      invocation
    )
  end

  @doc "Builds the durable event that schedules another squad provider attempt."
  @spec squad_provider_retry(Invocation.t(), map()) :: event_entry()
  def squad_provider_retry(invocation, error) do
    event(
      :squad_retry_scheduled,
      %{
        "turn_id" => invocation.turn_id,
        "room_id" => invocation.room_id,
        "seat_id" => invocation.participant.id,
        "attempt" => invocation.attempt + 1,
        "kind" => "provider_retry",
        "phase" => invocation.phase,
        "cycle" => invocation.cycle,
        "reason" => error["category"] || "provider_failure"
      },
      :turn,
      invocation.turn_id,
      invocation.room_id,
      invocation.turn_id
    )
  end

  @doc "Builds the aggregate and correlation metadata required by durable events."
  @spec aggregate_metadata(atom(), String.t(), String.t(), String.t()) :: keyword()
  def aggregate_metadata(type, aggregate_id, room_id, correlation_id) do
    [
      aggregate_type: type,
      aggregate_id: aggregate_id,
      room_id: room_id,
      correlation_id: correlation_id
    ]
  end

  defp event(type, data, aggregate_type, aggregate_id, room_id, correlation_id) do
    {
      type,
      data,
      aggregate_metadata(aggregate_type, aggregate_id, room_id, correlation_id)
    }
  end

  defp squad_rework_entry(turn, spec) do
    event(
      :squad_retry_scheduled,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.room_id,
        "seat_id" => "squad_leader",
        "attempt" => turn.squad.rework_count + 1,
        "kind" => "rework",
        "phase" => turn.squad.phase,
        "target_stage" => spec.stage,
        "target_phase" => spec.phase,
        "cycle" => spec.cycle,
        "reason" => "leader_requested_rework"
      },
      :turn,
      turn.id,
      turn.room_id,
      turn.id
    )
  end

  defp squad_stage_entry(turn, spec) do
    event(
      :squad_stage_entered,
      %{
        "turn_id" => turn.id,
        "room_id" => turn.room_id,
        "stage" => spec.stage,
        "phase" => spec.phase,
        "cycle" => spec.cycle
      },
      :turn,
      turn.id,
      turn.room_id,
      turn.id
    )
  end

  defp open_invocation_entry(room, turn, {spec, {invocation_id, message_id}}) do
    participant =
      Enum.find(room.participants, &(&1.id == spec.participant_id)) ||
        Map.get(spec, :participant)

    invocation_event(
      :assistant_message_opened,
      %{
        "invocation_id" => invocation_id,
        "message_id" => message_id,
        "turn_id" => turn.id,
        "room_id" => room.id,
        "participant" => wire_participant(participant),
        "stage" => spec.stage,
        "phase" => Map.get(spec, :phase, spec.label),
        "cycle" => Map.get(spec, :cycle, 0),
        "logical_work_id" => Map.get(spec, :logical_work_id, invocation_id),
        "dependencies" => Map.get(spec, :dependencies, []),
        "label" => spec.label,
        "system_prompt" => spec.system_prompt,
        "attempt" => Map.get(spec, :attempt, 1)
      },
      %Invocation{
        id: invocation_id,
        room_id: room.id,
        turn_id: turn.id
      }
    )
  end

  defp wire_participant(participant) do
    %{
      "id" => participant.id,
      "name" => participant.name,
      "perspective" => participant.perspective,
      "provider" => wire_provider(participant.provider),
      "model" => participant.model
    }
  end

  defp wire_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp wire_provider(provider), do: provider
end
