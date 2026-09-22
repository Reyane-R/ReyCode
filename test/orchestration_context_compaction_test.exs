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
    turn = %Turn{context_through_sequence: 3}

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
             ContextCompaction.entry(session, turn, projection, 100)

    assert data["through_sequence"] == 2
    assert data["source_message_count"] == 1
    assert data["source_bytes"] == byte_size(body)
    assert data["summary_bytes"] <= 400
    assert String.valid?(data["summary"])
    assert data["generator"] == "extractive-v2"
    assert metadata[:aggregate_id] == session.id
  end

  test "stops before the current Operator message and preserves it verbatim" do
    current_body = "Current request: keep café and 🙂 verbatim"

    session = %Session{
      id: "room-1",
      message_order: ["current", "eligible"],
      context_boundary_sequence: 1
    }

    eligible = message("eligible", session.id, String.duplicate("history ", 200), 4)
    current = message("current", session.id, current_body, 5)

    projection = %Projection{
      sequence: 8,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{eligible.id => eligible, current.id => current}
    }

    turn = %Turn{
      id: "turn-1",
      session_id: session.id,
      mode: :direct,
      context_through_sequence: current.created_sequence
    }

    assert {:compact, {:context_compacted, data, metadata}} =
             ContextCompaction.entry(session, turn, projection, 100)

    assert data["through_sequence"] == current.created_sequence - 1
    assert data["through_sequence"] > session.context_boundary_sequence
    refute data["summary"] =~ current_body

    compacted_projection =
      Projector.apply(Event.new(9, :context_compacted, data, metadata), projection)

    compacted = compacted_projection.sessions[session.id]

    invocation = %Invocation{id: "inv-1", session_id: session.id, turn_id: turn.id, rounds: []}

    assert [_, provider_current] =
             Context.messages(compacted, turn, invocation, compacted_projection)

    assert provider_current.content == current_body
    assert String.valid?(provider_current.content)
  end

  test "does not emit from an oversized previous summary without new eligible source" do
    session = %Session{
      id: "room-1",
      message_order: ["current"],
      context_boundary_sequence: 4,
      context_summary: String.duplicate("previous ", 200)
    }

    current = message("current", session.id, "Current request", 5)

    projection = %Projection{
      sequence: 6,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{current.id => current}
    }

    turn = %Turn{context_through_sequence: current.created_sequence}

    assert :unchanged = ContextCompaction.entry(session, turn, projection, 100)
  end

  test "preflight can shrink an existing summary without advancing its boundary" do
    session = %Session{
      id: "room-1",
      context_boundary_sequence: 4,
      context_summary: String.duplicate("previous ", 200)
    }

    projection = %Projection{
      sequence: 6,
      sessions: %{session.id => session},
      session_order: [session.id]
    }

    turn = %Turn{context_through_sequence: 5}

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.prepare(session, turn, projection, 128)

    assert data["through_sequence"] == session.context_boundary_sequence
    assert data["source_message_count"] == 0
    assert data["source_bytes"] == byte_size(session.context_summary)
    assert data["summary_bytes"] <= 128
    assert String.valid?(data["summary"])
  end

  test "preflight clamps an undersized allowance to one retained grapheme" do
    session = %Session{
      id: "room-1",
      context_boundary_sequence: 4,
      context_summary: String.duplicate("previous ", 20) <> "🙂"
    }

    projection = %Projection{sequence: 6, sessions: %{session.id => session}}
    turn = %Turn{context_through_sequence: 5}

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.prepare(session, turn, projection, 1)

    assert data["through_sequence"] == session.context_boundary_sequence
    assert data["summary"] == "…🙂"
  end

  test "does not compact a current message belonging to another nonterminal Turn" do
    older = message("older", "room-1", String.duplicate("history ", 200), 2)
    protected = message("protected", "room-1", "Concurrent current request", 4)
    later = message("later", "room-1", "Later request", 6)

    session = %Session{
      id: "room-1",
      message_order: ["later", "protected", "older"]
    }

    protected_turn = %Turn{
      id: "turn-protected",
      session_id: session.id,
      status: :running,
      context_through_sequence: protected.created_sequence
    }

    later_turn = %Turn{
      id: "turn-later",
      session_id: session.id,
      status: :running,
      context_through_sequence: later.created_sequence
    }

    protected = %{protected | turn_id: protected_turn.id}
    later = %{later | turn_id: later_turn.id}

    projection = %Projection{
      sequence: 8,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{older.id => older, protected.id => protected, later.id => later},
      turns: %{protected_turn.id => protected_turn, later_turn.id => later_turn}
    }

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.prepare(session, later_turn, projection, 400)

    assert data["through_sequence"] == protected.created_sequence - 1
    refute data["summary"] =~ protected.body
    refute data["summary"] =~ later.body
  end

  test "terminal failed output does not block later completed history" do
    older = message("older", "room-1", String.duplicate("old ", 200), 2)

    failed = %{
      message("failed", "room-1", "failed output", 3)
      | invocation_id: "inv-failed",
        status: :failed
    }

    newer = message("newer", "room-1", String.duplicate("new ", 200), 4)
    current = message("current", "room-1", "Current request", 6)

    session = %Session{
      id: "room-1",
      message_order: ["current", "newer", "failed", "older"]
    }

    failed_turn = %Turn{
      id: "turn-failed",
      session_id: session.id,
      status: :terminal,
      context_through_sequence: failed.created_sequence
    }

    current_turn = %Turn{
      id: "turn-current",
      session_id: session.id,
      status: :running,
      context_through_sequence: current.created_sequence
    }

    failed = %{failed | turn_id: failed_turn.id}
    older = %{older | turn_id: failed_turn.id}
    newer = %{newer | turn_id: failed_turn.id}
    current = %{current | turn_id: current_turn.id}

    projection = %Projection{
      sequence: 8,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{
        older.id => older,
        failed.id => failed,
        newer.id => newer,
        current.id => current
      },
      turns: %{failed_turn.id => failed_turn, current_turn.id => current_turn}
    }

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.prepare(session, current_turn, projection, 400)

    assert data["through_sequence"] == current.created_sequence - 1
    assert data["summary"] =~ "new "
    refute data["summary"] =~ failed.body
  end

  test "retains cumulative context and renders retained entries chronologically" do
    oldest_body = "oldest-" <> String.duplicate("o", 72)
    middle_body = "middle-" <> String.duplicate("m", 72)
    newest_body = "newest-" <> String.duplicate("n", 72)

    session = %Session{
      id: "room-1",
      message_order: ["newest", "middle", "oldest"],
      context_summary: "previous summary remains represented"
    }

    oldest = message("oldest", session.id, oldest_body, 2)
    middle = message("middle", session.id, middle_body, 3)
    newest = message("newest", session.id, newest_body, 4)

    projection = %Projection{
      sequence: 6,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{oldest.id => oldest, middle.id => middle, newest.id => newest}
    }

    turn = %Turn{context_through_sequence: 5}

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.entry(session, turn, projection, 56)

    summary = data["summary"]
    refute summary =~ oldest_body
    assert summary =~ session.context_summary
    assert summary =~ newest_body
    assert byte_size(summary) <= 56 * 4
    assert {previous_offset, _previous_length} = :binary.match(summary, session.context_summary)
    assert {newest_offset, _newest_length} = :binary.match(summary, newest_body)
    assert previous_offset < newest_offset
  end

  test "truncates a newest UTF-8 entry only at grapheme boundaries" do
    ending = "final-é-漢-🙂"
    body = String.duplicate("prefix ", 40) <> ending
    session = %Session{id: "room-1", message_order: ["message-1"]}
    source = message("message-1", session.id, body, 2)

    projection = %Projection{
      sequence: 4,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{source.id => source}
    }

    turn = %Turn{context_through_sequence: 3}

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.entry(session, turn, projection, 20)

    assert String.valid?(data["summary"])
    assert byte_size(data["summary"]) <= 20 * 4
    assert String.ends_with?(data["summary"], ending)
  end

  test "keeps the summary bounded when the allowance is smaller than its prefix" do
    body = String.duplicate("history ", 20) <> "x"
    session = %Session{id: "room-1", message_order: ["message-1"]}
    source = message("message-1", session.id, body, 2)

    projection = %Projection{
      sequence: 4,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{source.id => source}
    }

    turn = %Turn{context_through_sequence: 3}

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.entry(session, turn, projection, 1)

    assert data["summary"] == "…x"
    assert byte_size(data["summary"]) <= 4
    assert String.valid?(data["summary"])
  end

  test "does not advance an initial boundary with only an omission marker" do
    session = %Session{id: "room-1", message_order: ["message-1"]}
    source = message("message-1", session.id, "history🙂", 2)

    projection = %Projection{
      sequence: 4,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{source.id => source}
    }

    turn = %Turn{context_through_sequence: 3}

    assert :unchanged = ContextCompaction.prepare(session, turn, projection, 6)
  end

  test "does not advance when cumulative entries would contain only omission markers" do
    session = %Session{
      id: "room-1",
      message_order: ["message-1"],
      context_boundary_sequence: 1,
      context_summary: String.duplicate("Earlier durable context ", 20)
    }

    source = message("message-1", session.id, String.duplicate("new history ", 20), 2)

    projection = %Projection{
      sequence: 4,
      sessions: %{session.id => session},
      session_order: [session.id],
      messages: %{source.id => source}
    }

    turn = %Turn{context_through_sequence: 3}

    marker_only_bytes =
      byte_size("Earlier conversation context (extractive summary):\n" <> "…\n\n…")

    assert {:compact, {:context_compacted, data, _metadata}} =
             ContextCompaction.prepare(session, turn, projection, marker_only_bytes)

    assert data["through_sequence"] == session.context_boundary_sequence
    assert data["source_message_count"] == 0
    assert data["summary"] =~ "context "
    refute data["summary"] =~ source.body
  end

  test "provider context replaces boundary history with the durable summary" do
    session = %Session{
      id: "room-1",
      message_order: ["new", "old"],
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
