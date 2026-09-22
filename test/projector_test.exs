defmodule ReyCode.Orchestration.ProjectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @max_invocation_notes 100
  @max_replay_notes 110
  @max_provider_activity_events_count 256

  alias ReyCode.Event
  alias ReyCode.EventStore.SQLite.Checkpoint
  alias ReyCode.{Failure, Hashing}
  alias ReyCode.TUI.Activity

  alias ReyCode.Orchestration.{
    Author,
    Invocation,
    Message,
    Participant,
    Projector,
    ProviderRoundAttempt,
    Session,
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

    assert %Session{} = state.sessions["room-1"]
    assert %Participant{} = hd(state.sessions["room-1"].participants)
    assert %Message{} = state.messages["msg-agent"]
    assert %Turn{} = state.turns["turn-1"]
    assert %Invocation{} = state.invocations["inv-1"]
    assert state.sequence == 10
    assert state.session_order == ["room-1"]
    assert state.sessions["room-1"].message_order == ["msg-agent", "msg-user"]
    assert state.messages["msg-agent"].body == "Hello world"
    assert state.messages["msg-agent"].status == :completed
    assert state.turns["turn-1"].status == :terminal
    assert state.turns["turn-1"].outcome == :completed
    assert state.invocations["inv-1"].last_frame_sequence == 2
  end

  test "agent notes project into the invocation activity trail, never the body" do
    state =
      Projector.replay(
        opened_invocation_events() ++
          [
            event(5, :invocation_started, :invocation, "inv-1", %{
              "invocation_id" => "inv-1",
              "message_id" => "msg-assistant"
            }),
            note_event(6, "checking the workspace"),
            note_event(7, "reading config"),
            event(8, :provider_frame_recorded, :invocation, "inv-1", %{
              "invocation_id" => "inv-1",
              "message_id" => "msg-assistant",
              "frame_sequence" => 3,
              "kind" => "text_delta",
              "data" => %{"text" => "Answer"}
            })
          ]
      )

    invocation = state.invocations["inv-1"]

    assert invocation.notes == ["checking the workspace", "reading config"]
    assert invocation.last_frame_sequence == 3
    assert state.messages["msg-assistant"].body == "Answer"

    assert Enum.map(invocation.provider_activity_events, & &1["note"]) == [
             "reading config",
             "checking the workspace"
           ]
  end

  test "reasoning segment identity survives durable replay" do
    frames =
      Enum.map([{1, "Inspect "}, {2, "the project"}], fn {sequence, note} ->
        event(sequence + 4, :provider_frame_recorded, :invocation, "inv-1", %{
          "invocation_id" => "inv-1",
          "message_id" => "msg-assistant",
          "frame_sequence" => sequence,
          "kind" => "agent_note",
          "data" => %{"note" => note, "segment_sequence" => 1}
        })
      end)

    state = Projector.replay(opened_invocation_events() ++ frames)
    events = state.invocations["inv-1"].provider_activity_events
    assert Enum.all?(events, &(&1["segment_sequence"] == 1))

    assert [%Activity.TraceNote{text: "Inspect the project"}] =
             Activity.provider_trace(events, ".", 0)
  end

  test "provider tool events retain frame chronology for the execution ledger" do
    state =
      Projector.replay(
        opened_invocation_events() ++
          [
            event(5, :provider_frame_recorded, :invocation, "inv-1", %{
              "invocation_id" => "inv-1",
              "message_id" => "msg-assistant",
              "frame_sequence" => 1,
              "kind" => "tool_started",
              "data" => %{
                "tool" => "read",
                "state" => %{"tool_call_id" => "call-1", "status" => "running"}
              }
            }),
            event(6, :provider_frame_recorded, :invocation, "inv-1", %{
              "invocation_id" => "inv-1",
              "message_id" => "msg-assistant",
              "frame_sequence" => 2,
              "kind" => "tool_completed",
              "data" => %{
                "tool" => "read",
                "state" => %{"tool_call_id" => "call-1", "status" => "completed"}
              }
            })
          ]
      )

    assert [
             %{"frame_sequence" => 2, "kind" => "tool_completed"},
             %{"frame_sequence" => 1, "kind" => "tool_started"}
           ] = state.invocations["inv-1"].provider_activity_events
  end

  test "provider activity stays bounded and keeps the newest frame chronology" do
    frames =
      Enum.map(1..(@max_provider_activity_events_count + 10), fn frame_sequence ->
        event(frame_sequence + 4, :provider_frame_recorded, :invocation, "inv-1", %{
          "invocation_id" => "inv-1",
          "message_id" => "msg-assistant",
          "frame_sequence" => frame_sequence,
          "kind" => "tool_started",
          "data" => %{
            "tool" => "read",
            "state" => %{"tool_call_id" => "call-#{frame_sequence}", "status" => "running"}
          }
        })
      end)

    invocation =
      Projector.replay(opened_invocation_events() ++ frames).invocations["inv-1"]

    assert length(invocation.provider_activity_events) ==
             @max_provider_activity_events_count

    assert hd(invocation.provider_activity_events)["frame_sequence"] ==
             @max_provider_activity_events_count + 10

    assert List.last(invocation.provider_activity_events)["frame_sequence"] == 11
  end

  test "provider activity overflow retains the exact hidden reasoning row count" do
    note_count = 300

    frames =
      Enum.map(1..note_count, fn frame_sequence ->
        event(frame_sequence + 4, :provider_frame_recorded, :invocation, "inv-1", %{
          "invocation_id" => "inv-1",
          "message_id" => "msg-assistant",
          "frame_sequence" => frame_sequence,
          "kind" => "agent_note",
          "data" => %{"note" => "thought #{frame_sequence}\n   "}
        })
      end)

    invocation =
      Projector.replay(opened_invocation_events() ++ frames).invocations["inv-1"]

    assert length(invocation.provider_activity_events) ==
             @max_provider_activity_events_count

    assert %{
             "kind" => "activity_overflow",
             "hidden_note_row_count" => 45
           } = List.last(invocation.provider_activity_events)
  end

  test "the activity trail stays bounded and keeps the newest notes" do
    notes =
      Enum.map(1..(@max_replay_notes + 10), fn index ->
        note_event(index + 4, "note-#{index}")
      end)

    state = Projector.replay(opened_invocation_events() ++ notes)

    assert length(state.invocations["inv-1"].notes) == @max_invocation_notes

    assert [oldest | _] = state.invocations["inv-1"].notes
    assert oldest == "note-#{@max_replay_notes + 10 - @max_invocation_notes + 1}"

    assert List.last(state.invocations["inv-1"].notes) == "note-#{@max_replay_notes + 10}"
  end

  test "blank or malformed note payloads are dropped" do
    state =
      Projector.replay(
        opened_invocation_events() ++
          [
            note_event(5, ""),
            note_event(6, nil),
            note_event(7, "kept")
          ]
      )

    assert state.invocations["inv-1"].notes == ["kept"]
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
    [configured] = state.sessions["room-1"].participants

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

  test "provider round attempts project retries and clear when the round is recorded" do
    failure = Failure.new(:rate_limited, "Try later", true)

    invocation_started =
      event(5, :invocation_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant"
      })

    started =
      event(6, :provider_round_attempt_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => 0,
        "attempt" => 1,
        "frame_sequence_at_start" => 0,
        "provider_id" => "openai",
        "model_id" => "gpt-5",
        "request_metrics" => %{
          "prompt_bytes" => 8_000,
          "estimated_prompt_tokens" => 2_000
        }
      })

    scheduled =
      event(7, :provider_round_retry_scheduled, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => 0,
        "attempt" => 1,
        "retry_eligible_at" => "2026-08-03T00:00:00Z",
        "last_failure" => Failure.to_wire(failure)
      })

    retry_started =
      event(8, :provider_round_attempt_started, :invocation, "inv-1", %{
        started.data
        | "attempt" => 2,
          "request_metrics" => nil
      })

    round =
      event(9, :provider_round_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => 0,
        "text" => "complete",
        "tool_calls" => [],
        "usage" => %{"output_tokens" => 2}
      })

    started_state = Projector.replay(opened_invocation_events() ++ [invocation_started, started])
    attempt = started_state.invocations["inv-1"].provider_round_attempt

    assert %ProviderRoundAttempt{state: :started, attempt: 1} = attempt

    assert %ProviderRoundAttempt.RequestMetrics{
             prompt_bytes: 8_000,
             estimated_prompt_tokens: 2_000
           } = attempt.request_metrics

    assert started_state.invocations["inv-1"].last_request_metrics_sequence == started.sequence

    scheduled_state = Projector.apply(scheduled, started_state)
    scheduled_attempt = scheduled_state.invocations["inv-1"].provider_round_attempt
    assert scheduled_attempt.state == :retry_scheduled
    assert scheduled_attempt.retry_eligible_at == "2026-08-03T00:00:00Z"
    assert scheduled_attempt.last_failure == failure

    retry_state = Projector.apply(retry_started, scheduled_state)
    assert retry_state.invocations["inv-1"].provider_round_attempt.attempt == 2
    assert retry_state.invocations["inv-1"].provider_round_attempt.state == :started

    recorded_state = Projector.apply(round, retry_state)
    assert recorded_state.invocations["inv-1"].provider_round_attempt == nil
    assert [%{index: 0, text: "complete"}] = recorded_state.invocations["inv-1"].rounds
  end

  test "terminal invocation events clear an active provider round attempt" do
    invocation_started =
      event(5, :invocation_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant"
      })

    started =
      event(6, :provider_round_attempt_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => 0,
        "attempt" => 1,
        "frame_sequence_at_start" => 0,
        "provider_id" => "simulator",
        "model_id" => nil,
        "request_metrics" => nil
      })

    terminal_events = [
      {:invocation_completed, %{"metadata" => %{}}},
      {:invocation_failed, %{"error" => Failure.to_wire(Failure.new(:provider_error, "failed"))}},
      {:invocation_cancelled, %{"reason" => "cancelled"}}
    ]

    for {type, terminal_data} <- terminal_events do
      state = Projector.replay(opened_invocation_events() ++ [invocation_started, started])

      terminal =
        event(
          7,
          type,
          :invocation,
          "inv-1",
          Map.merge(
            %{
              "invocation_id" => "inv-1",
              "message_id" => "msg-assistant",
              "turn_id" => "turn-1",
              "room_id" => "room-1"
            },
            terminal_data
          )
        )

      projected = Projector.apply(terminal, state)
      assert projected.invocations["inv-1"].provider_round_attempt == nil
    end
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

  test "answer text resuming after a later provider round starts a new paragraph" do
    participant = %{
      "id" => "assistant",
      "name" => "Assistant",
      "perspective" => "primary",
      "provider" => "demo",
      "model" => nil
    }

    frame = fn sequence, frame_sequence, text ->
      event(sequence, :provider_frame_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "frame_sequence" => frame_sequence,
        "kind" => "text_delta",
        "data" => %{"text" => text}
      })
    end

    round_started = fn sequence, round_index, frame_sequence_at_start ->
      event(sequence, :provider_round_attempt_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => round_index,
        "attempt" => 1,
        "frame_sequence_at_start" => frame_sequence_at_start,
        "provider_id" => "demo",
        "model_id" => "demo",
        "request_metrics" => nil
      })
    end

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
        "body" => "Fix it"
      }),
      event(3, :turn_queued, :turn, "turn-1", %{
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "user_message_id" => "msg-user",
        "mode" => "compare",
        "context_through_sequence" => 2
      }),
      event(4, :turn_started, :turn, "turn-1", %{"turn_id" => "turn-1", "room_id" => "room-1"}),
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
      event(6, :invocation_started, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent"
      }),
      round_started.(7, 0, 0),
      frame.(8, 1, "Let me look."),
      frame.(9, 2, " Checking now."),
      event(10, :provider_round_recorded, :invocation, "inv-1", %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-agent",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => 0,
        "text" => "Let me look. Checking now.",
        "tool_calls" => [],
        "usage" => %{"output_tokens" => 2}
      }),
      round_started.(11, 1, 2),
      frame.(12, 3, "Found it."),
      frame.(13, 4, " Fixing.")
    ]

    state = Projector.replay(events)

    assert state.messages["msg-agent"].body ==
             "Let me look. Checking now.\n\nFound it. Fixing."
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
        session_id: "room-1",
        turn_id: "turn-1",
        message_id: "msg-assistant",
        pending_tool_review: %{
          request_id: "ask-legacy",
          tool: "read",
          arguments: %{},
          workspace: "/tmp",
          requested_at: "2026-08-03T00:00:00Z"
        },
        tool_events: [%{"kind" => "tool_started", "frame_sequence" => 1}]
      }

      assert %ToolAsk{request_id: "ask-legacy"} =
               Invocation.from_map(legacy_invocation).pending_tool_review

      assert [%{"kind" => "tool_started"}] =
               Invocation.from_map(legacy_invocation).provider_activity_events

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

    test "every from_map seam normalizes string-keyed and legacy shapes" do
      alias ReyCode.Orchestration.{Author, Message, ToolAsk}

      # Author passthrough keeps structs untouched.
      struct_author = %Author{kind: :agent, id: "a", name: "A"}
      assert Author.from_map(struct_author) == struct_author

      # Explicit wire kind wins over id inference.
      assert %{kind: :agent} =
               Author.from_map(%{"id" => "someone", "name" => "S", "kind" => "agent"})

      # Legacy snapshots attributed agents by builder/critic ids alone.
      assert %{kind: :agent} = Author.from_map(%{id: "builder", name: "B"})
      assert %{kind: :agent} = Author.from_map(%{"id" => "critic", "name" => "C"})

      # Unknown ids without a kind fall back to operator attribution.
      assert %{kind: :user} = Author.from_map(%{})

      # Message normalization wraps raw author maps.
      message = Message.from_map(%{id: "m", body: "", author: %{"id" => "x", "name" => "X"}})
      assert %{kind: :user, name: "X"} = message.author

      # ToolAsk accepts fully string-keyed wire maps.
      ask =
        ToolAsk.from_map(%{
          "request_id" => "req-9",
          "tool" => "grep",
          "arguments" => %{},
          "workspace" => "/tmp",
          "requested_at" => "t"
        })

      assert %{request_id: "req-9", tool: "grep"} = ask

      struct_ask = %ToolAsk{
        request_id: "r2",
        tool: "read",
        arguments: %{},
        workspace: "/tmp",
        requested_at: "t"
      }

      assert ToolAsk.from_map(struct_ask) == struct_ask

      # Structured retry elements keep their atom keys untouched.
      atom_retry = %{
        role_id: "implementer",
        attempt: 2,
        kind: "provider_retry",
        phase: "implementation",
        cycle: 0,
        reason: "timeout"
      }

      assert [%Retry{} = retry] = SquadRun.from_map(%{retries: [atom_retry]}).retries
      assert retry.attempt == 2

      struct_retry = %Retry{
        role_id: "x",
        attempt: 1,
        kind: "rework",
        phase: "p",
        cycle: 0,
        reason: "r"
      }

      assert Retry.from_map(struct_retry) == struct_retry
    end

    test "squad records normalize fully string-keyed legacy artifacts and retries" do
      run =
        SquadRun.from_map(%{
          artifacts: [
            %{
              "seat_id" => "analyst",
              "kind" => "stories",
              "phase" => "stories",
              "cycle" => 1,
              "summary" => "done",
              "blockers" => ["blocked"],
              "digest" => "d"
            }
          ],
          directives: [%{"text" => "slow down", "phase" => "build", "cycle" => 2}],
          retries: [
            %{
              "role_id" => "implementer",
              "attempt" => 3,
              "kind" => "provider_retry",
              "phase" => "implementation",
              "cycle" => 1,
              "reason" => "rate_limit"
            }
          ]
        })

      assert [
               %Artifact{
                 role_id: "analyst",
                 blockers: ["blocked"],
                 invocation_id: nil,
                 message_id: nil
               }
             ] = run.artifacts

      assert [%Directive{cycle: 2, recorded_at: nil}] = run.directives

      assert [%Retry{attempt: 3, kind: "provider_retry", reason: "rate_limit"}] = run.retries
    end
  end

  test "legacy token budgets and exhaustion failures survive event and checkpoint replay" do
    legacy =
      Enum.map(opened_invocation_events(), fn
        %Event{type: :assistant_message_opened} = opened ->
          %{
            opened
            | data:
                Map.merge(opened.data, %{"model_tier" => "smol", "token_budget_tokens" => 32_000})
          }

        event ->
          event
      end)

    failure = Failure.new(:token_budget_exceeded, "Token budget exhausted: 102345/32000")

    events =
      legacy ++
        [
          event(5, :turn_started, :turn, "turn-1", %{"room_id" => "room-1", "turn_id" => "turn-1"}),
          event(6, :invocation_started, :invocation, "inv-1", %{
            "invocation_id" => "inv-1",
            "message_id" => "msg-assistant"
          }),
          event(7, :provider_frame_recorded, :invocation, "inv-1", %{
            "invocation_id" => "inv-1",
            "message_id" => "msg-assistant",
            "frame_sequence" => 1,
            "kind" => "usage",
            "data" => %{"usage" => %{"total_tokens" => 102_345}}
          }),
          event(8, :invocation_failed, :invocation, "inv-1", %{
            "invocation_id" => "inv-1",
            "message_id" => "msg-assistant",
            "error" => Failure.to_wire(failure)
          }),
          event(9, :turn_completed, :turn, "turn-1", %{
            "room_id" => "room-1",
            "turn_id" => "turn-1",
            "outcome" => "failed"
          })
        ]

    projection = Projector.replay(events)
    assert projection.invocations["inv-1"].execution_context.token_budget_tokens == 32_000
    assert projection.invocations["inv-1"].usage == %{"total_tokens" => 102_345}
    assert projection.invocations["inv-1"].error.category == :token_budget_exceeded
    encoded = projection |> Checkpoint.encode_term() |> Jason.encode!()

    assert {:ok, decoded} =
             Checkpoint.decode(
               encoded,
               Checkpoint.projection_version(),
               projection.sequence,
               Hashing.sha256_hex(encoded),
               1_000_000
             )

    assert Projector.replay([], decoded) == projection
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

  defp note_event(sequence, note) do
    event(sequence, :provider_frame_recorded, :invocation, "inv-1", %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-assistant",
      "frame_sequence" => sequence - 3,
      "kind" => "agent_note",
      "data" => %{"note" => note}
    })
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
