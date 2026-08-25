defmodule ReyCode.Orchestration.ProjectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Event

  alias ReyCode.Orchestration.{
    Author,
    Invocation,
    Message,
    Participant,
    Projector,
    Room,
    SquadRun,
    ToolAsk,
    Turn
  }

  alias ReyCode.Orchestration.Squad.{Artifact, Directive, GateResolution, GateReview, Retry}

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

    assert %Room{} = state.rooms["room-1"]
    assert %Participant{} = hd(state.rooms["room-1"].participants)
    assert %Message{} = state.messages["msg-agent"]
    assert %Turn{} = state.turns["turn-1"]
    assert %Invocation{} = state.invocations["inv-1"]
    assert state.sequence == 10
    assert state.room_order == ["room-1"]
    assert state.rooms["room-1"].message_order == ["msg-agent", "msg-user"]
    assert state.messages["msg-agent"].body == "Hello world"
    assert state.messages["msg-agent"].status == :completed
    assert state.turns["turn-1"].status == :terminal
    assert state.turns["turn-1"].outcome == :completed
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

    assert [%GateReview{} = review] = state.turns["turn-squad"].squad.reviews
    assert review.recommendation.role_id == "squad_leader"
    assert review.recommendation.decision == "approve"
    assert state.turns["turn-squad"].squad.pending_review == nil

    assert [%GateResolution{} = resolution] = state.turns["turn-squad"].squad.resolutions
    assert resolution.authority == :owner
    assert resolution.resolver_id == "human_owner"
    assert state.turns["turn-squad"].squad.latest_resolution == resolution
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

  describe "typed projected records" do
    test "messages attribute authors as Author structs" do
      state = replay_room_message("Signed message")

      assert %Author{kind: :user, id: "user", name: "You"} =
               state.messages["msg-user"].author
    end

    test "assistant messages attribute agents from participants" do
      state =
        Projector.replay(opened_invocation_events())

      assert %Author{kind: :agent, id: "builder", name: "Builder"} =
               state.messages["msg-assistant"].author
    end

    test "tool asks project into ToolAsk structs from events and tool runs" do
      ask_event =
        event(3, :tool_ask_requested, :invocation, "inv-1", %{
          "invocation_id" => "inv-1",
          "message_id" => "msg-assistant",
          "turn_id" => "turn-1",
          "room_id" => "room-1",
          "request_id" => "ask-1",
          "tool" => "shell",
          "arguments" => %{"command" => "ls"},
          "workspace" => "/tmp/alpha"
        })

      state = Projector.replay(opened_invocation_events() ++ [ask_event])

      assert %ToolAsk{} =
               review = state.invocations["inv-1"].pending_tool_review

      assert review.request_id == "ask-1"
      assert review.tool == "shell"
      assert review.arguments == %{"command" => "ls"}
    end

    test "squad artifacts, retries, and directives project as typed records" do
      state =
        Projector.replay(
          squad_seed_events() ++
            [
              event(4, :squad_artifact_recorded, :turn, "turn-squad", %{
                "turn_id" => "turn-squad",
                "seat_id" => "analyst",
                "kind" => "stories",
                "phase" => "stories",
                "cycle" => 0,
                "invocation_id" => "inv-analyst",
                "message_id" => "msg-analyst",
                "summary" => "wrote stories",
                "blockers" => [],
                "digest" => "abc"
              }),
              event(5, :squad_retry_scheduled, :turn, "turn-squad", %{
                "turn_id" => "turn-squad",
                "seat_id" => "implementer",
                "attempt" => 2,
                "kind" => "provider_retry",
                "phase" => "implementation",
                "cycle" => 0,
                "reason" => "rate_limit"
              }),
              event(6, :squad_directive_added, :turn, "turn-squad", %{
                "turn_id" => "turn-squad",
                "text" => "Keep the first release read-only.",
                "phase" => "stories",
                "cycle" => 0
              })
            ]
        )

      squad = state.turns["turn-squad"].squad

      assert [%Artifact{} = artifact] = squad.artifacts
      assert artifact.role_id == "analyst"
      assert artifact.summary == "wrote stories"

      assert [%Retry{} = retry] = squad.retries
      assert retry.role_id == "implementer"
      assert retry.kind == "provider_retry"

      assert [%Directive{} = directive] = squad.directives
      assert directive.text == "Keep the first release read-only."
    end

    test "legacy snapshots normalize nested maps into typed records" do
      legacy_invocation = %{
        id: "inv-1",
        room_id: "room-1",
        turn_id: "turn-1",
        message_id: "msg-assistant",
        pending_tool_review: %{
          request_id: "ask-legacy",
          tool: "read",
          arguments: %{},
          workspace: "/tmp",
          requested_at: "2026-08-03T00:00:00Z"
        }
      }

      assert %ToolAsk{request_id: "ask-legacy"} =
               Invocation.from_map(legacy_invocation).pending_tool_review

      legacy_run = %{
        artifacts: [
          %{
            seat_id: "analyst",
            kind: "stories",
            phase: "stories",
            invocation_id: "inv-analyst",
            message_id: "msg-a"
          }
        ],
        directives: [%{"text" => "focus", "phase" => "plan", "recorded_at" => "t"}],
        retries: [%{"role_id" => "implementer", "attempt" => 2, "phase" => "build"}]
      }

      run = SquadRun.from_map(legacy_run)

      assert [%Artifact{role_id: "analyst", summary: ""}] =
               run.artifacts

      assert [%Directive{text: "focus", cycle: 0}] = run.directives
      assert [%Retry{role_id: "implementer", cycle: 0}] = run.retries
    end
  end

  defp seed_events do
    [
      room_created_event(),
      event(2, :message_posted, :room, "room-1", user_message_data())
    ]
  end

  defp replay_room_message(body) do
    Projector.replay([
      room_created_event(),
      event(2, :message_posted, :room, "room-1", %{user_message_data() | "body" => body})
    ])
  end

  defp room_created_event do
    event(1, :room_created, :room, "room-1", %{
      "room_id" => "room-1",
      "slug" => "alpha",
      "title" => "Alpha",
      "workspace" => "/tmp/alpha",
      "participants" => [participant_wire()]
    })
  end

  defp participant_wire do
    %{
      "id" => "builder",
      "name" => "Builder",
      "perspective" => "implementation",
      "provider" => "demo",
      "model" => nil,
      "kind" => "primary"
    }
  end

  defp user_message_data do
    %{
      "message_id" => "msg-user",
      "room_id" => "room-1",
      "turn_id" => "turn-1",
      "author_name" => "You",
      "body" => "Hello"
    }
  end

  defp opened_invocation_events do
    seed_events() ++
      [
        event(3, :turn_queued, :turn, "turn-1", %{
          "turn_id" => "turn-1",
          "room_id" => "room-1",
          "user_message_id" => "msg-user",
          "mode" => "direct",
          "context_through_sequence" => 2
        }),
        event(4, :assistant_message_opened, :invocation, "inv-1", %{
          "invocation_id" => "inv-1",
          "message_id" => "msg-assistant",
          "turn_id" => "turn-1",
          "room_id" => "room-1",
          "participant" => participant_wire(),
          "stage" => 0,
          "label" => "response",
          "system_prompt" => nil,
          "cycle" => 0,
          "dependencies" => [],
          "attempt" => 1
        })
      ]
  end

  defp squad_seed_events do
    [
      room_created_event(),
      event(2, :message_posted, :room, "room-1", user_message_data()),
      event(3, :turn_queued, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "user_message_id" => "msg-user",
        "mode" => "squad",
        "context_through_sequence" => 2
      }),
      event(4, :squad_configured, :turn, "turn-squad", %{
        "turn_id" => "turn-squad",
        "room_id" => "room-1",
        "seats" => ["squad_leader"],
        "rework_budget" => 2
      })
    ]
  end
end
