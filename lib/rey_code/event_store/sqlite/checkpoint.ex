defmodule ReyCode.EventStore.SQLite.Checkpoint do
  @moduledoc """
  Pure encoding, decoding, and validation for Projection checkpoints.

  Checkpoints are JSON documents with an explicit typed wire format. Encoding
  strips internal struct tags recursively, preserving a map-based durable
  contract. Decoding validates version, payload size, checksum, known atoms,
  required shape, and stored sequence before returning data. Any uncertainty
  returns a tagged error; the Engine decides whether recovery may fall back to
  event replay. Three recent checkpoints are retained.
  """

  alias ReyCode.Hashing

  @projection_version 3
  @legacy_projection_version 2
  @retention 3

  @required_keys ~w(sessions session_order messages turns invocations)a

  @doc "Returns the checkpoint wire-format version this build understands."
  @spec projection_version() :: pos_integer()
  def projection_version, do: @projection_version

  @doc "Returns how many recent checkpoints are retained."
  @spec retention() :: pos_integer()
  def retention, do: @retention

  @doc "Encodes any acyclic term made of atoms/binaries/numbers/tuples/lists/maps."
  @spec encode_term(term()) :: iodata()
  def encode_term(value) when is_atom(value), do: ["atom", Atom.to_string(value)]
  def encode_term(value) when is_binary(value), do: ["binary", value]
  def encode_term(value) when is_integer(value), do: ["integer", value]
  def encode_term(value) when is_float(value), do: ["float", value]

  def encode_term(value) when is_list(value),
    do: ["list", Enum.map(value, &encode_term/1)]

  def encode_term(value) when is_tuple(value) do
    ["tuple", value |> Tuple.to_list() |> Enum.map(&encode_term/1)]
  end

  def encode_term(%_module{} = value), do: value |> Map.from_struct() |> encode_term()

  def encode_term(value) when is_map(value) do
    pairs =
      Enum.map(value, fn {key, item} -> [encode_term(key), encode_term(item)] end)

    ["map", pairs]
  end

  @doc """
  Validates and decodes one stored checkpoint row.

  Rejects unsupported projection versions, non-binary or oversized payloads,
  checksum mismatches, undecodable terms, and projections whose sequence or
  required keys do not match.
  """
  @spec decode(term(), term(), term(), term(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def decode(encoded, version, sequence, checksum, max_bytes) do
    with :ok <- validate_version(version),
         :ok <- validate_payload(encoded, max_bytes),
         :ok <- validate_checksum(encoded, checksum),
         {:ok, wire} <- Jason.decode(encoded),
         {:ok, projection} <- decode_term(wire),
         {:ok, projection} <- normalize_projection_keys(projection),
         :ok <- validate_projection(projection, sequence) do
      {:ok, projection}
    end
  end

  defp validate_version(@projection_version), do: :ok
  defp validate_version(@legacy_projection_version), do: :ok
  defp validate_version(version), do: {:error, {:unsupported_projection, version}}

  defp validate_payload(encoded, max_bytes) when is_binary(encoded) do
    if byte_size(encoded) <= max_bytes,
      do: :ok,
      else: {:error, :checkpoint_too_large}
  end

  defp validate_payload(_encoded, _max_bytes), do: {:error, :invalid_checkpoint}

  defp validate_checksum(encoded, checksum) do
    if Hashing.sha256_hex(encoded) == checksum,
      do: :ok,
      else: {:error, :checkpoint_checksum_mismatch}
  end

  defp validate_projection(projection, sequence) do
    if valid_projection?(projection, sequence),
      do: :ok,
      else: {:error, :invalid_checkpoint}
  end

  defp valid_projection?(projection, sequence) do
    projection[:sequence] == sequence and
      Enum.all?(@required_keys, &Map.has_key?(projection, &1))
  end

  defp normalize_projection_keys(%{} = projection) do
    {legacy_sessions, projection} = Map.pop(projection, :rooms)
    {legacy_order, projection} = Map.pop(projection, :room_order)

    projection =
      projection
      |> put_legacy(:sessions, legacy_sessions)
      |> put_legacy(:session_order, legacy_order)

    {:ok, projection}
  end

  defp normalize_projection_keys(_projection), do: {:error, :invalid_checkpoint}
  defp put_legacy(map, _key, nil), do: map
  defp put_legacy(map, key, value), do: Map.put_new(map, key, value)

  defp decode_term(["atom", value]) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :invalid_checkpoint}
  end

  defp decode_term(["binary", value]) when is_binary(value), do: {:ok, value}
  defp decode_term(["integer", value]) when is_integer(value), do: {:ok, value}
  defp decode_term(["float", value]) when is_float(value), do: {:ok, value}

  defp decode_term(["list", values]) when is_list(values), do: decode_terms(values)

  defp decode_term(["tuple", values]) when is_list(values) do
    case decode_terms(values) do
      {:ok, decoded} -> {:ok, List.to_tuple(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_term(["map", pairs]) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      [encoded_key, encoded_value], {:ok, map} ->
        with {:ok, key} <- decode_term(encoded_key),
             {:ok, value} <- decode_term(encoded_value) do
          {:cont, {:ok, Map.put(map, key, value)}}
        else
          {:error, :invalid_checkpoint} = error -> {:halt, error}
        end

      _pair, _result ->
        {:halt, {:error, :invalid_checkpoint}}
    end)
  end

  defp decode_term(_value), do: {:error, :invalid_checkpoint}

  defp decode_terms(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decode_term(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, :invalid_checkpoint} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, :invalid_checkpoint} = error -> error
    end
  end
end
