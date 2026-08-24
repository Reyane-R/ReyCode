defmodule ReyCode.EventStore.SQLite.Checkpoint do
  @moduledoc """
  Pure encoding, decoding, and validation for projection checkpoints.

  Checkpoints are JSON documents whose terms use an explicit typed wire
  format (tagged atoms/binaries/tuples/lists/maps), bound by a checksum,
  byte cap, projection version, and shape validation against the stored
  sequence.
  """

  alias ReyCode.Hashing

  @projection_version 2
  @retention 3

  @required_keys ~w(rooms room_order messages turns invocations)a

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
    with true <- version == @projection_version || {:error, {:unsupported_projection, version}},
         true <- is_binary(encoded) || {:error, :invalid_checkpoint},
         true <- byte_size(encoded) <= max_bytes || {:error, :checkpoint_too_large},
         true <-
           Hashing.sha256_hex(encoded) == checksum || {:error, :checkpoint_checksum_mismatch},
         {:ok, wire} <- Jason.decode(encoded),
         {:ok, projection} <- decode_term(wire),
         true <- valid_projection?(projection, sequence) || {:error, :invalid_checkpoint} do
      {:ok, projection}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_checkpoint}
    end
  end

  defp valid_projection?(projection, sequence) do
    is_map(projection) and projection[:sequence] == sequence and
      Enum.all?(@required_keys, &Map.has_key?(projection, &1))
  end

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
