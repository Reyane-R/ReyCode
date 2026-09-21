defmodule ReyCode.Orchestration.InvocationContextBoundary do
  @moduledoc "Durable summary boundary over a completed prefix of one Invocation's rounds."

  @maximum_summary_bytes 32_768
  @generators ~w(extractive-v1 semantic-v1)
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @enforce_keys [
    :through_round_index,
    :summary,
    :source_digest,
    :source_round_count,
    :source_bytes,
    :summary_bytes,
    :generator
  ]
  defstruct @enforce_keys ++ [recorded_at: nil]

  @type t :: %__MODULE__{
          through_round_index: non_neg_integer(),
          summary: String.t(),
          source_digest: String.t(),
          source_round_count: pos_integer(),
          source_bytes: pos_integer(),
          summary_bytes: pos_integer(),
          generator: String.t(),
          recorded_at: String.t() | nil
        }

  @doc "Maximum persisted summary size."
  @spec maximum_summary_bytes() :: pos_integer()
  def maximum_summary_bytes, do: @maximum_summary_bytes

  @doc "Builds and validates a boundary from atom- or string-keyed data."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_invocation_context_boundary}
  def new(data) when is_map(data) do
    boundary = %__MODULE__{
      through_round_index: fetch(data, :through_round_index),
      summary: fetch(data, :summary),
      source_digest: fetch(data, :source_digest),
      source_round_count: fetch(data, :source_round_count),
      source_bytes: fetch(data, :source_bytes),
      summary_bytes: fetch(data, :summary_bytes),
      generator: fetch(data, :generator),
      recorded_at: fetch(data, :recorded_at)
    }

    if valid?(boundary),
      do: {:ok, boundary},
      else: {:error, :invalid_invocation_context_boundary}
  end

  def new(_data), do: {:error, :invalid_invocation_context_boundary}

  @doc "Restores a projected boundary and raises on corrupt durable state."
  @spec from_map(t() | map() | nil) :: t() | nil
  def from_map(nil), do: nil
  def from_map(%__MODULE__{} = boundary), do: boundary

  def from_map(data) do
    case new(data) do
      {:ok, boundary} ->
        boundary

      {:error, :invalid_invocation_context_boundary} ->
        raise ArgumentError, "invalid InvocationContextBoundary"
    end
  end

  @doc "Converts a boundary to its event wire representation."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = boundary) do
    %{
      "through_round_index" => boundary.through_round_index,
      "summary" => boundary.summary,
      "source_digest" => boundary.source_digest,
      "source_round_count" => boundary.source_round_count,
      "source_bytes" => boundary.source_bytes,
      "summary_bytes" => boundary.summary_bytes,
      "generator" => boundary.generator
    }
  end

  defp valid?(boundary) do
    valid_index?(boundary) and valid_summary?(boundary) and valid_source?(boundary) and
      boundary.generator in @generators and valid_recorded_at?(boundary.recorded_at)
  end

  defp valid_index?(boundary),
    do: is_integer(boundary.through_round_index) and boundary.through_round_index >= 0

  defp valid_summary?(boundary) do
    is_binary(boundary.summary) and boundary.summary != "" and
      is_integer(boundary.summary_bytes) and
      byte_size(boundary.summary) == boundary.summary_bytes and
      boundary.summary_bytes in 1..@maximum_summary_bytes
  end

  defp valid_source?(boundary) do
    is_binary(boundary.source_digest) and
      Regex.match?(@digest_pattern, boundary.source_digest) and
      is_integer(boundary.source_round_count) and boundary.source_round_count > 0 and
      boundary.source_round_count == boundary.through_round_index + 1 and
      is_integer(boundary.source_bytes) and boundary.source_bytes > 0
  end

  defp valid_recorded_at?(nil), do: true
  defp valid_recorded_at?(recorded_at), do: is_binary(recorded_at)

  defp fetch(data, field), do: Map.get(data, field, Map.get(data, Atom.to_string(field)))
end
