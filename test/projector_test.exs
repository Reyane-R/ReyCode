defmodule ReyCode.Orchestration.ProjectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Event
  alias ReyCode.Orchestration.Projector

  test "replay rebuilds room messages, turns, and streamed invocations" do
    participant = %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "implementation",
      "provider" => "demo",
      "model" => nil
    }

    events = [
      event(1, :room_created, :room, "room-1", %{
        "room_id" => "room-1",
        "slug" => "alpha",
        "title" => "Alpha",
        "workspace" => "/tmp/alpha",
        "participants" => [participant]
      }),
      event(2, :message_posted, :room, "room-1", %{
        "message_id" => "msg-user",
        "room_id" => "room-1",
        "turn_id" => "turn-1",
        "author_name" => "You",
        "body" => "Design it"
      }),
      event(3, :turn_queued, :turn, "turn-1", %{
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "user_message_id" => "msg-user",
        "mode" => "compare",
        "context_through_sequence" => 2
      }),
      event(4, :turn_started, :turn, "turn-1", %{
        "turn_id" => "turn-1",
        "room_id" => "room-1"
      }),
      event(5, :assistant_message_opened, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "participant" => participant,
        "stage" => 0,
        "label" => "independent response",
        "system_prompt" => "Respond",
        "attempt" => 1
      }),
      event(6, :invocation_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent"
      }),
      event(7, :provider_frame_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "frame_sequence" => 1,
        "kind" => "text_delta",
        "data" => %{"text" => "Hello "}
      }),
      event(8, :provider_frame_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "frame_sequence" => 2,
        "kind" => "text_delta",
        "data" => %{"text" => "world"}
      }),
      event(9, :invocation_completed, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent"
      }),
      event(10, :turn_completed, :turn, "turn-1", %{
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "outcome" => "completed"
      })
    ]

    state = Projector.replay(events)

    assert state.sequence == 10
    assert state.room_order == ["room-1"]
    assert state.rooms["room-1"].message_order == ["msg-agent", "msg-user"]
    assert state.messages["msg-agent"].body == "Hello world"
    assert state.messages["msg-agent"].status == :completed
    assert state.turns["turn-1"].status == :completed
    assert state.invocations["inv-1"].last_frame_sequence == 2
  end

  test "participant provider and model configuration survives replay" do
    participant = %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "implementation",
      "provider" => "demo",
      "model" => nil
    }

    events = [
      event(1, :room_created, :room, "room-1", %{
        "room_id" => "room-1",
        "slug" => "alpha",
        "title" => "Alpha",
        "workspace" => "/tmp/alpha",
        "participants" => [participant]
      }),
      event(2, :participant_configured, :room, "room-1", %{
        "room_id" => "room-1",
        "participant_id" => "builder",
        "provider" => "opencode",
        "model" => "openai/gpt-5.6-sol"
      })
    ]

    state = Projector.replay(events)
    [configured] = state.rooms["room-1"].participants

    assert configured.provider == :opencode
    assert configured.model == "openai/gpt-5.6-sol"
    assert state.sequence == 2
  end

  test "provider frames project text, usage, and strict sequence state" do
    participant = %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "implementation",
      "provider" => "demo",
      "model" => nil
    }

    events = [
      event(1, :room_created, :room, "room-1", %{
        "room_id" => "room-1",
        "slug" => "alpha",
        "title" => "Alpha",
        "workspace" => "/tmp/alpha",
        "participants" => [participant]
      }),
      event(2, :message_posted, :room, "room-1", %{
        "message_id" => "msg-user",
        "room_id" => "room-1",
        "turn_id" => "turn-1",
        "author_name" => "You",
        "body" => "Design it"
      }),
      event(3, :turn_queued, :turn, "turn-1", %{
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "user_message_id" => "msg-user",
        "mode" => "compare",
        "context_through_sequence" => 2
      }),
      event(4, :turn_started, :turn, "turn-1", %{
        "turn_id" => "turn-1",
        "room_id" => "room-1"
      }),
      event(5, :assistant_message_opened, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "participant" => participant,
        "stage" => 0,
        "label" => "response",
        "system_prompt" => "Respond",
        "attempt" => 1
      }),
      event(6, :provider_frame_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "frame_sequence" => 1,
        "kind" => "text_delta",
        "data" => %{"text" => "Hello"}
      }),
      event(7, :provider_frame_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "frame_sequence" => 2,
        "kind" => "usage",
        "data" => %{"usage" => %{"output_tokens" => 4}}
      })
    ]

    state = Projector.replay(events)
    invocation = state.invocations["inv-1"]

    assert state.messages["msg-agent"].body == "Hello"
    assert invocation.usage == %{"output_tokens" => 4}
    assert invocation.last_frame_sequence == 2
  end

  test "replays a legacy projection snapshot" do
    participant = %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "implementation",
      "provider" => "demo",
      "model" => nil
    }

    room_event =
      event(1, :room_created, :room, "room-1", %{
        "room_id" => "room-1",
        "slug" => "snap",
        "title" => "Snap",
        "workspace" => "/tmp/snap",
        "participants" => [participant]
      })

    pre_snapshot = Projector.replay([room_event])

    snapshot_event =
      event(2, :snapshot_recorded, :system, "snapshot", %{
        "binary" => pre_snapshot |> :erlang.term_to_binary() |> Base.encode64()
      })

    post_event =
      event(3, :message_posted, :room, "room-1", %{
        "message_id" => "msg-after",
        "room_id" => "room-1",
        "turn_id" => "turn-1",
        "author_name" => "You",
        "body" => "After snapshot"
      })

    state = Projector.replay([room_event, snapshot_event, post_event])
    expected = Projector.apply(post_event, %{pre_snapshot | sequence: 2})

    assert state == expected
  end

  test "projects durable owner directives and release review decisions" do
    events = [
      event(1, :room_created, :room, "room-1", %{
        "room_id" => "room-1",
        "slug" => "alpha",
        "title" => "Alpha",
        "workspace" => "/tmp/alpha",
        "participants" => []
      }),
      event(2, :message_posted, :room, "room-1", %{
        "message_id" => "msg-user",
        "room_id" => "room-1",
        "turn_id" => "turn-squad",
        "body" => "Deliver it"
      }),
      event(3, :turn_queued, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "user_message_id" => "msg-user",
        "mode" => "squad",
        "context_through_sequence" => 2
      }),
      event(4, :turn_started, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1"
      }),
      event(5, :squad_configured, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "seats" => [],
        "rework_budget" => 3,
        "phase" => "stories"
      }),
      event(6, :squad_directive_added, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "text" => "Keep the first release read-only.",
        "phase" => "stories",
        "cycle" => 0
      }),
      event(7, :gate_review_requested, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "seat_id" => "squad_leader",
        "decision" => "approve",
        "phase" => "release_gate",
        "cycle" => 0,
        "target_phase" => nil,
        "reasons" => ["All evidence is complete"]
      }),
      event(8, :gate_resolved, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "seat_id" => "human_owner",
        "decision" => "approve",
        "phase" => "release_gate",
        "cycle" => 0,
        "target_phase" => nil,
        "reasons" => ["Owner accepted the evidence"]
      })
    ]

    state = Projector.replay(events)

    assert [directive] = state.turns["turn-squad"].squad.directives
    assert directive.text == "Keep the first release read-only."
    assert directive.phase == "stories"
    assert directive.cycle == 0
    assert directive.recorded_at == "2026-08-03T00:00:00Z"

    assert [review] = state.turns["turn-squad"].squad.gate_reviews
    assert review.actor == "agent"
    assert review.decision == "approve"
    assert state.turns["turn-squad"].squad.pending_review == nil

    assert [decision] = state.turns["turn-squad"].squad.decisions
    assert decision.actor == "human"
    assert decision.role_id == "human_owner"
    assert state.turns["turn-squad"].squad.latest_gate == decision
  end

  property "replay preserves arbitrary message bodies" do
    check all(body <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      events = [
        event(1, :room_created, :room, "room-prop", %{
          "room_id" => "room-prop",
          "slug" => "prop",
          "title" => "Property",
          "workspace" => "/tmp/prop",
          "participants" => []
        }),
        event(2, :message_posted, :room, "room-prop", %{
          "message_id" => "msg-prop",
          "room_id" => "room-prop",
          "turn_id" => "turn-prop",
          "author_name" => "You",
          "body" => body
        })
      ]

      state = Projector.replay(events)

      assert state.sequence == 2
      assert state.messages["msg-prop"].body == body
    end
  end

  defp event(sequence, type, aggregate_type, aggregate_id, data) do
    %Event{
      id: Integer.to_string(sequence),
      sequence: sequence,
      schema_version: 2,
      type: type,
      aggregate_type: aggregate_type,
      aggregate_id: aggregate_id,
      room_id: data["room_id"] || "room-1",
      correlation_id: data["turn_id"],
      causation_id: nil,
      data: data,
      recorded_at: "2026-08-03T00:00:00Z"
    }
  end
end
