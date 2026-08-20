defmodule ReyCode.Event do
  @moduledoc "A versioned durable fact stored in global sequence order."

  alias ReyCode.JSON

  @schema_version 2

  @enforce_keys [
    :id,
    :sequence,
    :schema_version,
    :type,
    :aggregate_type,
    :aggregate_id,
    :data,
    :recorded_at
  ]
  defstruct [
    :id,
    :sequence,
    :schema_version,
    :type,
    :aggregate_type,
    :aggregate_id,
    :room_id,
    :correlation_id,
    :causation_id,
    :data,
    :recorded_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          sequence: pos_integer(),
          schema_version: pos_integer(),
          type: type(),
          aggregate_type: atom(),
          aggregate_id: String.t(),
          room_id: String.t() | nil,
          correlation_id: String.t() | nil,
          causation_id: String.t() | nil,
          data: map(),
          recorded_at: String.t()
        }

  @types ~w(
    room_created participant_configured message_posted turn_queued turn_started assistant_message_opened
    invocation_started provider_frame_recorded invocation_completed invocation_failed invocation_cancelled
    turn_completed snapshot_recorded squad_configured squad_stage_entered squad_decision_recorded
    squad_artifact_recorded squad_retry_scheduled squad_role_configured squad_directive_added
    gate_review_requested gate_resolved squad_budget_extended
  )a
  @type type ::
          unquote(
            @types
            |> Enum.reduce(fn type, union -> {:|, [], [union, type]} end)
          )
  @type_lookup Map.new(@types, &{Atom.to_string(&1), &1})
  @known_types MapSet.new(@types)

  @required_data %{
    room_created: ~w(room_id slug title workspace participants),
    participant_configured: ~w(room_id participant_id provider model),
    message_posted: ~w(message_id room_id turn_id body),
    turn_queued: ~w(turn_id room_id user_message_id mode context_through_sequence),
    turn_started: ~w(turn_id room_id),
    assistant_message_opened:
      ~w(invocation_id message_id turn_id room_id participant stage label system_prompt),
    invocation_started: ~w(invocation_id message_id turn_id room_id),
    provider_frame_recorded: ~w(invocation_id message_id frame_sequence kind data),
    invocation_completed: ~w(invocation_id message_id turn_id room_id),
    invocation_failed: ~w(invocation_id message_id turn_id room_id error),
    invocation_cancelled: ~w(invocation_id message_id turn_id room_id reason),
    turn_completed: ~w(turn_id room_id outcome),
    snapshot_recorded: ~w(binary),
    squad_configured: ~w(turn_id room_id seats rework_budget),
    squad_stage_entered: ~w(turn_id room_id stage),
    squad_decision_recorded: ~w(turn_id room_id seat_id decision),
    squad_artifact_recorded: ~w(turn_id room_id seat_id kind),
    squad_retry_scheduled: ~w(turn_id room_id seat_id attempt),
    squad_role_configured: ~w(room_id role_id provider model),
    squad_directive_added: ~w(turn_id room_id text phase cycle),
    gate_review_requested: ~w(turn_id room_id seat_id decision phase cycle),
    gate_resolved: ~w(turn_id room_id seat_id decision phase cycle),
    squad_budget_extended: ~w(turn_id room_id budget)
  }

  @doc "Returns the event schema version accepted by this module."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version
  @doc "Returns the canonical list of event type atoms."
  @spec types() :: [atom()]
  def types, do: Map.values(@type_lookup)

  @doc "Returns the required data keys for a given event type, or nil if unknown."
  @spec required_data_keys(atom()) :: [String.t()] | nil
  def required_data_keys(type), do: Map.get(@required_data, type)

  @doc "Builds and validates an event for an assigned global sequence."
  @spec new(pos_integer(), type(), map(), keyword()) :: t()
  def new(sequence, type, data, metadata \\ []) when is_map(data) do
    data = JSON.normalize(data)

    event = %__MODULE__{
      id: Integer.to_string(sequence),
      sequence: sequence,
      schema_version: @schema_version,
      type: type,
      aggregate_type: Keyword.fetch!(metadata, :aggregate_type),
      aggregate_id: Keyword.fetch!(metadata, :aggregate_id),
      room_id: metadata[:room_id],
      correlation_id: metadata[:correlation_id],
      causation_id: metadata[:causation_id],
      data: data,
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }

    validate!(event)
  end

  @doc "Validates an event's type, aggregate identity, sequence, and required data."
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = event) do
    unless event.type in @known_types,
      do: raise(ArgumentError, "unknown event type #{inspect(event.type)}")

    unless event.aggregate_type in [:room, :turn, :invocation, :system],
      do: raise(ArgumentError, "invalid aggregate type")

    unless nonempty_string?(event.aggregate_id), do: raise(ArgumentError, "invalid aggregate id")

    unless is_integer(event.sequence) and event.sequence > 0,
      do: raise(ArgumentError, "invalid event sequence")

    unless is_map(event.data), do: raise(ArgumentError, "invalid event data")

    missing = Enum.reject(Map.fetch!(@required_data, event.type), &Map.has_key?(event.data, &1))

    unless missing == [],
      do: raise(ArgumentError, "missing event data: #{Enum.join(missing, ", ")}")

    event
  end

  @doc "Encodes an event as JSON, raising when encoding fails."
  @spec encode!(t()) :: String.t()
  def encode!(event), do: Jason.encode!(event)

  @doc "Decodes and validates a JSON event in the current schema."
  @spec decode!(String.t()) :: t()
  def decode!(line), do: line |> Jason.decode!() |> decode_value!()

  @doc "Converts a decoded JSON map into a validated current-schema event."
  @spec decode_value!(map()) :: t()
  def decode_value!(value) when is_map(value) do
    if value["schema_version"] != @schema_version do
      raise ArgumentError,
            "unsupported ReyCode event schema #{inspect(value["schema_version"])}; expected #{@schema_version}"
    end

    event = %__MODULE__{
      id: value["id"],
      sequence: value["sequence"],
      schema_version: value["schema_version"],
      type: Map.fetch!(@type_lookup, value["type"]),
      aggregate_type: aggregate_type(value["aggregate_type"]),
      aggregate_id: value["aggregate_id"],
      room_id: value["room_id"],
      correlation_id: value["correlation_id"],
      causation_id: value["causation_id"],
      data: value["data"],
      recorded_at: value["recorded_at"]
    }

    validate!(event)
  end

  defp aggregate_type("room"), do: :room
  defp aggregate_type("turn"), do: :turn
  defp aggregate_type("invocation"), do: :invocation
  defp aggregate_type("system"), do: :system

  defp nonempty_string?(value), do: is_binary(value) and value != ""
end

defimpl Jason.Encoder, for: ReyCode.Event do
  def encode(event, opts) do
    Jason.Encode.map(
      %{
        id: event.id,
        sequence: event.sequence,
        schema_version: event.schema_version,
        type: event.type,
        aggregate_type: event.aggregate_type,
        aggregate_id: event.aggregate_id,
        room_id: event.room_id,
        correlation_id: event.correlation_id,
        causation_id: event.causation_id,
        data: event.data,
        recorded_at: event.recorded_at
      },
      opts
    )
  end
end
