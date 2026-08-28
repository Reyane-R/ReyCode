defmodule ReyCode.Orchestration.ContextCompactionTest do
  use ExUnit.Case, async: true

  alias ReyCode.Event

  alias ReyCode.Orchestration.{
    Author,
    Context,
    ContextCompaction,
    Invocation,
    Message,
    Projection,
    Projector,
    Session,
    Turn
  }

  test "emits a bounded append-only compaction boundary when context exceeds budget" do
    body = String.duplicate("history ", 1_000)
    session = %Session{id: "room-1", message_order: ["message-1"]}

    message = %Message{
      id: "message-1",
      session_id: session.id,
      author: Author.user("You"),
      role: :user,
      status: :completed,
      body: body,
      created_sequence: 2
    }

    projection = %Projection{
      sequence: 4,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{message.id => message}
    }

    assert {:compact, {:context_compacted, data, metadata}} =
             ContextCompaction.entry(session, projection, 100)

    assert data["through_sequence"] == 4
    assert data["source_message_count"] == 1
    assert data["source_bytes"] == byte_size(body)
    assert data["summary_bytes"] <= 400
    assert String.valid?(data["summary"])
    assert metadata[:aggregate_id] == session.id
  end

  test "provider context replaces boundary history with the durable summary" do
    session = %Session{
      id: "room-1",
      message_order: ["old", "new"],
      context_boundary_sequence: 3,
      context_summary: "You asked about the release."
    }

    old = message("old", session.id, "old text", 2)
    new = message("new", session.id, "new text", 4)

    projection = %Projection{
      sequence: 5,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{old.id => old, new.id => new}
    }

    turn = %Turn{id: "turn-1", session_id: session.id, mode: :direct, context_through_sequence: 5}
    invocation = %Invocation{id: "inv-1", session_id: session.id, turn_id: turn.id, rounds: []}

    assert [summary, current] = Context.messages(session, turn, invocation, projection)
    assert summary.role == :user
    assert summary.content =~ "durable extractive summary"
    assert summary.content =~ session.context_summary
    assert current.content == "new text"
  end

  test "projector keeps the newest compaction boundary without deleting messages" do
    room_event =
      Event.new(
        1,
        :room_created,
        %{
          "room_id" => "room-1",
          "slug" => "room",
          "title" => "Room",
          "workspace" => "/tmp",
          "participants" => []
        },
        aggregate_type: :room,
        aggregate_id: "room-1",
        room_id: "room-1"
      )

    compacted =
      Event.new(
        2,
        :context_compacted,
        %{
          "room_id" => "room-1",
          "through_sequence" => 1,
          "summary" => "summary",
          "source_message_count" => 0,
          "source_bytes" => 0,
          "summary_bytes" => 7,
          "generator" => "extractive-v1"
        },
        aggregate_type: :room,
        aggregate_id: "room-1",
        room_id: "room-1"
      )

    projection = Projector.replay([room_event, compacted])
    session = projection.sessions["room-1"]

    assert session.context_boundary_sequence == 1
    assert session.context_summary == "summary"
    assert projection.sequence == 2
  end

  defp message(id, session_id, body, sequence) do
    %Message{
      id: id,
      session_id: session_id,
      author: Author.user("You"),
      role: :user,
      status: :completed,
      body: body,
      created_sequence: sequence
    }
  end
end
