defmodule ReyCode.EventStore.LegacyNDJSON do
  @moduledoc """
  Read-only compatibility reader for schema-v2 NDJSON event logs.

  The active event store is SQLite-only. This module exists solely to read
  legacy `events-v2.ndjson` logs during one-time imports: it understands
  one-event records, transaction envelopes, and snapshot trimming, repairs an
  unterminated final newline, truncates a torn final record, and validates
  global sequence contiguity.
  """

  require Logger

  alias ReyCode.Event
  alias ReyCode.EventStore.Record

  @doc "Reads all events in sequence order, returning them with their last sequence."
  @spec read(Path.t()) :: {[Event.t()], non_neg_integer()}
  def read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {events, tail, tail_offset} = read_records(file)

          events =
            case {tail, Jason.decode(tail)} do
              {"", _result} ->
                events

              {_tail, {:ok, value}} ->
                events ++ Record.decode_value!(value)

              {_tail, {:error, _reason}} ->
                truncate_torn_tail!(path, tail_offset, byte_size(tail))
                events
            end

          validate_sequence!(events)
          {events, last_sequence(events)}
        after
          File.close(file)
        end

      {:error, :enoent} ->
        {[], 0}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read event log", path: path
    end
  end

  @doc "Appends a missing trailing newline so future appends stay line-oriented."
  @spec normalize_tail!(Path.t()) :: :ok
  def normalize_tail!(path) do
    case File.open(path, [:read, :write, :binary]) do
      {:ok, file} ->
        try do
          {:ok, eof_size} = :file.position(file, :eof)

          if eof_size > 0 do
            {:ok, _position} = :file.position(file, eof_size - 1)
            {:ok, last_byte} = :file.read(file, 1)

            if last_byte != "\n" do
              :ok = IO.binwrite(file, "\n")
              :file.sync(file)
              Logger.info("normalized event log tail path=#{path}")
            end
          end
        after
          File.close(file)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "normalize event log", path: path
    end
  end

  defp read_records(file) do
    {events, tail, tail_offset} =
      file
      |> IO.binstream(:line)
      |> Enum.reduce({[], "", 0}, fn raw_line, {acc, tail, offset} ->
        if String.ends_with?(raw_line, "\n") do
          {keep_line(acc, String.trim_trailing(raw_line, "\n")), tail,
           offset + byte_size(raw_line)}
        else
          {acc, String.trim_trailing(raw_line, "\n"), offset}
        end
      end)

    {Enum.reverse(events), tail, tail_offset}
  end

  defp keep_line(acc, ""), do: acc

  defp keep_line(acc, line) do
    batch = Record.decode!(line)

    if Enum.any?(batch, &(&1.type == :snapshot_recorded)) do
      Enum.reverse(batch)
    else
      Enum.reverse(batch) ++ acc
    end
  end

  defp last_sequence(events) do
    case List.last(events) do
      nil -> 0
      event -> event.sequence
    end
  end

  defp truncate_torn_tail!(path, offset, removed_bytes) do
    {:ok, :ok} =
      File.open(path, [:read, :write, :binary], fn file ->
        {:ok, ^offset} = :file.position(file, offset)
        :ok = :file.truncate(file)
        :file.sync(file)
      end)

    Logger.warning(
      "truncated incomplete event log tail path=#{path} removed_bytes=#{removed_bytes}"
    )
  end

  defp validate_sequence!([]), do: :ok

  defp validate_sequence!([%Event{type: :snapshot_recorded} | _] = events) do
    validate_from(events, events |> hd() |> Map.fetch!(:sequence))
  end

  defp validate_sequence!(events), do: validate_from(events, 1)

  defp validate_from(events, expected) do
    result =
      Enum.reduce_while(events, expected, fn event, expected ->
        if event.sequence == expected, do: {:cont, expected + 1}, else: {:halt, :error}
      end)

    if result == :error, do: raise("event log sequence is not contiguous")
  end
end
