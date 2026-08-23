defmodule ReyCode.EventStore.LegacyNDJSONTest do
  @moduledoc """
  Focused coverage for the read-only schema-v2 NDJSON importer: record
  shapes, torn tails, malformed records, sequence validation, and tail
  normalization. The active store never writes this format.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReyCode.Event
  alias ReyCode.EventStore.LegacyNDJSON
  alias ReyCode.EventStore.Record

  test "reads one-event-per-line records in sequence order" do
    path = tmp_path("legacy.ndjson")

    write!(
      path,
      Event.encode!(event(1, :room_created)) <> "\n" <> Event.encode!(event(2, :message_posted))
    )

    assert {[first, second], 2} = LegacyNDJSON.read(path)
    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "reads a transaction envelope and trims at snapshot records" do
    path = tmp_path("envelope.ndjson")

    write!(
      path,
      Record.encode!([event(1, :room_created), event(2, :message_posted)]) <>
        "\n" <>
        Event.encode!(snapshot_event(3)) <>
        "\n" <>
        Event.encode!(event(4, :message_posted)) <> "\n"
    )

    assert {events, 4} = LegacyNDJSON.read(path)
    assert Enum.map(events, & &1.sequence) == [3, 4]
  end

  test "ignores and warns about an incomplete unterminated final tail without modifying it" do
    path = tmp_path("torn-tail.ndjson")
    complete = Event.encode!(event(1, :room_created)) <> "\n"
    write!(path, complete <> ~s({"record_type":"transaction","first_sequence":2))

    log =
      capture_log(fn ->
        assert {[only], 1} = LegacyNDJSON.read(path)
        assert only.sequence == 1
      end)

    assert log =~ "ignored incomplete event log tail"
    assert File.read!(path) == complete <> ~s({"record_type":"transaction","first_sequence":2)

    assert :ok = LegacyNDJSON.repair_torn_tail!(path)
    assert File.read!(path) == complete
  end

  test "fails on a malformed complete record" do
    path = tmp_path("malformed.ndjson")
    write!(path, Event.encode!(event(1, :room_created)) <> "\nnot-json\n")

    assert_raise Jason.DecodeError, fn -> LegacyNDJSON.read(path) end
  end

  test "validates transaction metadata and global sequence contiguity" do
    invalid_count_path = tmp_path("invalid-count.ndjson")

    write!(
      invalid_count_path,
      Jason.encode!(%{
        "record_type" => "transaction",
        "first_sequence" => 1,
        "event_count" => 2,
        "events" => [event_value(1)]
      }) <> "\n"
    )

    assert_raise ArgumentError, ~r/event_count/, fn -> LegacyNDJSON.read(invalid_count_path) end

    sequence_gap_path = tmp_path("sequence-gap.ndjson")
    write!(sequence_gap_path, Event.encode!(event(2, :room_created)) <> "\n")

    assert_raise RuntimeError, "event log sequence is not contiguous", fn ->
      LegacyNDJSON.read(sequence_gap_path)
    end
  end

  test "normalizes a missing trailing newline for line-oriented appends" do
    path = tmp_path("unterminated-tail.ndjson")

    contents =
      Event.encode!(event(1, :room_created)) <> "\n" <> Event.encode!(event(2, :message_posted))

    write!(path, contents)

    :ok = LegacyNDJSON.normalize_tail!(path)

    assert File.read!(path) == contents <> "\n"
    assert {events, 2} = LegacyNDJSON.read(path)
    assert Enum.map(events, & &1.sequence) == [1, 2]
  end

  test "returns an empty log for missing files" do
    assert {[], 0} = LegacyNDJSON.read(tmp_path("missing.ndjson"))
  end

  defp tmp_path(filename) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "rey_code_legacy_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, filename)
  end

  defp event(sequence, type) do
    Event.new(sequence, type, event_data(type), metadata())
  end

  defp snapshot_event(sequence) do
    Event.new(
      sequence,
      :snapshot_recorded,
      %{"binary" => "snap"},
      aggregate_type: :system,
      aggregate_id: "snapshot",
      room_id: nil
    )
  end

  defp event_data(:room_created) do
    %{
      "room_id" => "room-1",
      "slug" => "alpha",
      "title" => "Alpha",
      "workspace" => "/tmp/alpha",
      "participants" => []
    }
  end

  defp event_data(:message_posted) do
    %{
      "message_id" => "msg-1",
      "room_id" => "room-1",
      "turn_id" => "turn-1",
      "body" => "Hello"
    }
  end

  defp metadata do
    [aggregate_type: :room, aggregate_id: "room-1", room_id: "room-1"]
  end

  defp event_value(sequence) do
    sequence
    |> event(:room_created)
    |> Event.encode!()
    |> Jason.decode!()
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
