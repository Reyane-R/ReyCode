defmodule ReyCode.Orchestration.EventEntriesTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{EventEntries, Squad}
  alias ReyCode.Provider.Frame

  @turn_metadata [
    aggregate_type: :turn,
    aggregate_id: "turn-1",
    room_id: "room-1",
    correlation_id: "turn-1"
  ]

  test "builds room creation and queued turn entries with exact metadata and ordering" do
    participants = [%{"id" => "builder"}]

    assert EventEntries.session_created(
             "room-1",
             "room",
             "Room",
             "/workspace",
             participants
           ) ==
             {
               :room_created,
               %{
                 "room_id" => "room-1",
                 "slug" => "room",
                 "title" => "Room",
                 "workspace" => "/workspace",
                 "participants" => participants
               },
               [aggregate_type: :room, aggregate_id: "room-1", room_id: "room-1"]
             }

    assert EventEntries.queue_turn(
             "room-1",
             "Ship it",
             :debate,
             "turn-1",
             "msg-1",
             7,
             :operator,
             nil
           ) == [
             {
               :message_posted,
               %{
                 "message_id" => "msg-1",
                 "room_id" => "room-1",
                 "turn_id" => "turn-1",
                 "author_name" => "You",
                 "body" => "Ship it"
               },
               [
                 aggregate_type: :room,
                 aggregate_id: "room-1",
                 room_id: "room-1",
                 correlation_id: "turn-1"
               ]
             },
             {
               :turn_queued,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "user_message_id" => "msg-1",
                 "mode" => "debate",
                 "context_through_sequence" => 7,
                 "input_kind" => "operator",
                 "participant_id" => nil
               },
               @turn_metadata
             }
           ]
  end

  test "builds participant and squad role configuration entries in input order" do
    assert [builder, critic] =
             EventEntries.participant_configuration(
               "room-1",
               ["builder", "critic"],
               :opencode,
               "openai/gpt-5"
             )

    assert elem(builder, 0) == :participant_configured
    assert elem(builder, 1)["participant_id"] == "builder"
    assert elem(builder, 1)["provider"] == "opencode"
    assert elem(builder, 1)["model"] == "openai/gpt-5"
    assert elem(builder, 2) == room_metadata()
    assert elem(critic, 1)["participant_id"] == "critic"

    role = Squad.role("analyst")

    assert EventEntries.squad_role_configuration("room-1", [role.id], :simulator, nil) == [
             {
               :squad_role_configured,
               %{
                 "room_id" => "room-1",
                 "role_id" => role.id,
                 "name" => role.name,
                 "perspective" => role.perspective,
                 "provider" => "simulator",
                 "model" => nil
               },
               room_metadata()
             }
           ]
  end

  test "builds turn and invocation lifecycle entries" do
    turn = %{id: "turn-1", session_id: "room-1"}

    invocation = %{
      id: "inv-1",
      message_id: "msg-1",
      turn_id: "turn-1",
      session_id: "room-1"
    }

    assert EventEntries.turn_started(turn) ==
             {:turn_started, %{"turn_id" => "turn-1", "room_id" => "room-1"}, @turn_metadata}

    assert EventEntries.turn_completed(turn, :partial) ==
             {
               :turn_completed,
               %{"turn_id" => "turn-1", "room_id" => "room-1", "outcome" => "partial"},
               @turn_metadata
             }

    assert EventEntries.invocation_started(invocation) ==
             {
               :invocation_started,
               %{
                 "invocation_id" => "inv-1",
                 "message_id" => "msg-1",
                 "turn_id" => "turn-1",
                 "room_id" => "room-1"
               },
               invocation_metadata("inv-1")
             }

    assert EventEntries.provider_frame(invocation, Frame.text_delta(3, "next")) ==
             {
               :provider_frame_recorded,
               %{
                 "frame_sequence" => 3,
                 "kind" => "text_delta",
                 "data" => %{"text" => "next"},
                 "invocation_id" => "inv-1",
                 "message_id" => "msg-1",
                 "turn_id" => "turn-1",
                 "room_id" => "room-1"
               },
               invocation_metadata("inv-1")
             }
  end

  test "builds squad directive and gate resolution entries" do
    turn = %{
      id: "turn-1",
      session_id: "room-1",
      squad: %{phase: "release_gate", cycle: 2}
    }

    assert EventEntries.squad_directive(turn, "Keep it read-only") ==
             {
               :squad_directive_added,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "text" => "Keep it read-only",
                 "phase" => "release_gate",
                 "cycle" => 2
               },
               @turn_metadata
             }

    review = %{phase: "release_gate", cycle: 2}

    assert EventEntries.gate_resolved(
             turn,
             review,
             :rework,
             "qa_validation",
             ["Missing evidence"]
           ) ==
             {
               :gate_resolved,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "seat_id" => "human_owner",
                 "decision" => "rework",
                 "phase" => "release_gate",
                 "cycle" => 2,
                 "target_phase" => "qa_validation",
                 "reasons" => ["Missing evidence"]
               },
               @turn_metadata
             }
  end

  test "builds cancellation entries in invocation order followed by the turn completion" do
    turn = %{id: "turn-1", session_id: "room-1"}

    invocations = [
      %{id: "inv-1", message_id: "msg-1", turn_id: "turn-1", session_id: "room-1"},
      %{id: "inv-2", message_id: "msg-2", turn_id: "turn-1", session_id: "room-1"}
    ]

    assert [first, second, completed] =
             EventEntries.cancel_turn(turn, invocations, "User stopped the turn")

    assert first ==
             {
               :invocation_cancelled,
               %{
                 "invocation_id" => "inv-1",
                 "message_id" => "msg-1",
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "reason" => "User stopped the turn"
               },
               invocation_metadata("inv-1")
             }

    assert elem(second, 1)["invocation_id"] == "inv-2"

    assert completed ==
             {
               :turn_completed,
               %{"turn_id" => "turn-1", "room_id" => "room-1", "outcome" => "cancelled"},
               @turn_metadata
             }
  end

  test "builds squad start entries with supplied configuration" do
    turn = %{id: "turn-1", session_id: "room-1"}

    assert [configured, entered] =
             EventEntries.squad_start(turn,
               rework_budget: 5,
               release_authority: :owner
             )

    assert configured ==
             {
               :squad_configured,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "seats" => Enum.map(Squad.roles(), & &1.id),
                 "rework_budget" => 5,
                 "release_authority" => "human",
                 "workflow_version" => Squad.workflow_version(),
                 "phase" => Squad.phase_label(0)
               },
               @turn_metadata
             }

    assert entered ==
             {
               :squad_stage_entered,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "stage" => 0,
                 "phase" => Squad.phase_label(0),
                 "cycle" => 0
               },
               @turn_metadata
             }
  end

  test "builds squad rework and stage transition entries" do
    turn = %{
      id: "turn-1",
      session_id: "room-1",
      squad: %{cycle: 1, phase_index: 4, phase: "specification", rework_count: 2}
    }

    rework_spec = %{phase_index: 2, phase: "story_review", cycle: 2}

    assert [rework] = EventEntries.squad_continue(turn, [rework_spec])

    assert rework ==
             {
               :squad_retry_scheduled,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "seat_id" => "squad_leader",
                 "attempt" => 3,
                 "kind" => "rework",
                 "phase" => "specification",
                 "target_stage" => 2,
                 "target_phase" => "story_review",
                 "cycle" => 2,
                 "reason" => "leader_requested_rework"
               },
               @turn_metadata
             }

    transition_spec = %{phase_index: 5, phase: "specification_gate", cycle: 1}

    assert EventEntries.squad_continue(turn, [transition_spec]) == [
             {
               :squad_stage_entered,
               %{
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "stage" => 5,
                 "phase" => "specification_gate",
                 "cycle" => 1
               },
               @turn_metadata
             }
           ]

    assert EventEntries.squad_continue(turn, [
             %{phase_index: 4, phase: "specification", cycle: 1}
           ]) ==
             []
  end

  test "treats an empty squad continuation as a no-op" do
    assert EventEntries.squad_continue(%{}, []) == []
  end

  test "builds invocation entries from generated IDs and spec defaults" do
    participant = %{
      id: "builder",
      name: "Builder",
      perspective: "implementation",
      provider: :simulator,
      model: nil,
      kind: :task
    }

    session = %{id: "room-1", participants: [participant]}
    turn = %{id: "turn-1"}

    spec = %{
      participant_id: "builder",
      phase_index: 0,
      label: "independent response",
      system_prompt: "Respond independently"
    }

    assert EventEntries.open_invocations(session, turn, [spec], [{"inv-1", "msg-1"}]) == [
             {
               :assistant_message_opened,
               %{
                 "invocation_id" => "inv-1",
                 "message_id" => "msg-1",
                 "turn_id" => "turn-1",
                 "room_id" => "room-1",
                 "participant" => %{
                   "id" => "builder",
                   "name" => "Builder",
                   "perspective" => "implementation",
                   "provider" => "simulator",
                   "model" => nil,
                   "model_tier" => "default",
                   "kind" => "task"
                 },
                 "stage" => 0,
                 "phase" => "independent response",
                 "cycle" => 0,
                 "logical_work_id" => "inv-1",
                 "dependencies" => [],
                 "label" => "independent response",
                 "system_prompt" => "Respond independently",
                 "project_instructions" => "",
                 "project_instruction_digest" => nil,
                 "project_instruction_sources" => [],
                 "model_tier" => "default",
                 "token_budget_tokens" => 100_000,
                 "output_schema" => nil,
                 "workspace" => "",
                 "workspace_roots" => [],
                 "isolation" => nil,
                 "attempt" => 1
               },
               invocation_metadata("inv-1")
             }
           ]
  end

  test "rejects generated IDs that do not match invocation specs" do
    session = %{id: "room-1", participants: []}
    turn = %{id: "turn-1"}

    spec = %{
      participant_id: "builder",
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "implementation",
        provider: :simulator,
        model: nil
      },
      phase_index: 0,
      label: "independent response",
      system_prompt: "Respond independently"
    }

    assert_raise ArgumentError, ~r/got 1 specs and 0 ID pairs/, fn ->
      EventEntries.open_invocations(session, turn, [spec], [])
    end

    assert_raise ArgumentError, ~r/got 0 specs and 1 ID pairs/, fn ->
      EventEntries.open_invocations(session, turn, [], [{"inv-1", "msg-1"}])
    end

    assert EventEntries.open_invocations(session, turn, [], []) == []
  end

  defp invocation_metadata(invocation_id) do
    [
      aggregate_type: :invocation,
      aggregate_id: invocation_id,
      room_id: "room-1",
      correlation_id: "turn-1"
    ]
  end

  defp room_metadata do
    [
      aggregate_type: :room,
      aggregate_id: "room-1",
      room_id: "room-1",
      correlation_id: "room-1"
    ]
  end
end
