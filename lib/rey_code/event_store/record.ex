defmodule ReyCode.EventStore.Record do
  @moduledoc false

  alias ReyCode.Event

  @record_type "transaction"
  @envelope_keys ~w(record_type first_sequence event_count events)

  @spec encode!([Event.t()]) :: String.t()
  def encode!([first | _] = events) do
    Jason.encode!(%{
      "record_type" => @record_type,
      "first_sequence" => first.sequence,
      "event_count" => length(events),
      "events" => events
    })
  end

  @spec decode!(String.t()) :: [Event.t()]
  def decode!(line), do: line |> Jason.decode!() |> decode_value!()

  @spec decode_value!(term()) :: [Event.t()]
  def decode_value!(value) when is_map(value) do
    if Enum.any?(@envelope_keys, &Map.has_key?(value, &1)) do
      decode_envelope!(value)
    else
      [Event.decode_value!(value)]
    end
  end

  def decode_value!(_value), do: raise(ArgumentError, "event log record must be a JSON object")

  defp decode_envelope!(envelope) do
    record_type = Map.get(envelope, "record_type")
    first_sequence = Map.get(envelope, "first_sequence")
    event_count = Map.get(envelope, "event_count")
    values = Map.get(envelope, "events")

    validate_record_type!(record_type)
    validate_positive!(first_sequence, "first_sequence")
    validate_positive!(event_count, "event_count")
    validate_values!(values, event_count, first_sequence)

    Enum.map(values, &Event.decode_value!/1)
  end

  defp validate_record_type!(record_type) when record_type in [nil, @record_type], do: :ok

  defp validate_record_type!(record_type) do
    raise ArgumentError, "unsupported event log record type #{inspect(record_type)}"
  end

  defp validate_positive!(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(_value, field) do
    raise ArgumentError, "transaction #{field} must be a positive integer"
  end

  defp validate_values!(values, event_count, first_sequence) when is_list(values) do
    unless length(values) == event_count do
      raise ArgumentError, "transaction event_count does not match its events"
    end

    values
    |> Enum.with_index(first_sequence)
    |> Enum.each(&validate_sequence!/1)
  end

  defp validate_values!(_values, _event_count, _first_sequence) do
    raise ArgumentError, "transaction events must be a list"
  end

  defp validate_sequence!({value, expected_sequence}) do
    unless is_map(value) and value["sequence"] == expected_sequence do
      raise ArgumentError, "transaction event sequence does not match first_sequence"
    end
  end
end
