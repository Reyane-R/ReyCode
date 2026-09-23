defmodule ReyCode.Provider.TextBuffer do
  @moduledoc "UTF-8-safe, latency-aware buffering for provider text deltas."

  @enforce_keys [:chunk_bytes, :chunk_latency_ms]
  defstruct pending: "",
            started_at: nil,
            chunk_bytes: nil,
            chunk_latency_ms: nil,
            flush_tail_on_size?: false

  @type t :: %__MODULE__{
          pending: binary(),
          started_at: integer() | nil,
          chunk_bytes: pos_integer(),
          chunk_latency_ms: non_neg_integer(),
          flush_tail_on_size?: boolean()
        }

  @doc "Creates a text buffer with required byte and latency flush limits."
  @spec new(keyword()) :: t()
  def new(opts) do
    chunk_bytes = Keyword.fetch!(opts, :chunk_bytes)
    chunk_latency_ms = Keyword.fetch!(opts, :chunk_latency_ms)
    flush_tail? = Keyword.get(opts, :flush_tail_on_size?, false)

    if is_integer(chunk_bytes) and chunk_bytes > 0 and is_integer(chunk_latency_ms) and
         chunk_latency_ms >= 0 and is_boolean(flush_tail?) do
      %__MODULE__{
        chunk_bytes: chunk_bytes,
        chunk_latency_ms: chunk_latency_ms,
        flush_tail_on_size?: flush_tail?
      }
    else
      raise ArgumentError, "invalid text buffer limits"
    end
  end

  @doc "Appends text and emits UTF-8-safe chunks when a configured limit is reached."
  @spec append(t(), binary(), integer()) :: {[binary()], t()}
  def append(buffer, text, now \\ System.monotonic_time(:millisecond))
  def append(buffer, "", _now), do: {[], buffer}

  def append(buffer, text, now) do
    started_at = buffer.started_at || now
    buffer = %{buffer | pending: buffer.pending <> text, started_at: started_at}
    elapsed = now - started_at

    cond do
      elapsed >= buffer.chunk_latency_ms ->
        drain(buffer, :latency, now)

      byte_size(buffer.pending) >= buffer.chunk_bytes ->
        drain(buffer, if(buffer.flush_tail_on_size?, do: :latency, else: :size), now)

      true ->
        {[], buffer}
    end
  end

  @doc """
  Emits all pending text as UTF-8-safe chunks.

  This is the final flush for the text: a trailing partial codepoint that
  never completed is replaced rather than emitted as broken bytes.
  """
  @spec flush(t(), integer()) :: {[binary()], t()}
  def flush(buffer, now \\ System.monotonic_time(:millisecond)) do
    drain(buffer, :final, now)
  end

  @doc "Returns the absolute monotonic deadline for pending text, or nil when empty."
  @spec next_flush_deadline(t()) :: integer() | nil
  def next_flush_deadline(%__MODULE__{pending: ""}), do: nil

  def next_flush_deadline(%__MODULE__{started_at: started_at, chunk_latency_ms: latency})
      when is_integer(started_at),
      do: started_at + latency

  @doc """
  Flushes pending text only when its latency deadline has been reached.

  More text may still follow, so a trailing partial codepoint stays pending
  until the bytes that complete it arrive.
  """
  @spec flush_due(t(), integer()) :: {[binary()], t()}
  def flush_due(buffer, now \\ System.monotonic_time(:millisecond)) do
    case next_flush_deadline(buffer) do
      deadline when is_integer(deadline) and now >= deadline -> drain(buffer, :latency, now)
      _deadline -> {[], buffer}
    end
  end

  @doc "Truncates a binary to a byte limit without returning a partial UTF-8 codepoint."
  @spec truncate_utf8(binary(), non_neg_integer()) :: binary()
  def truncate_utf8(_value, 0), do: ""
  def truncate_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  def truncate_utf8(value, max_bytes) do
    value |> binary_part(0, max_bytes) |> trim_invalid_suffix()
  end

  defp drain(%{pending: ""} = buffer, _mode, _now), do: {[], %{buffer | started_at: nil}}

  # Providers split multibyte characters across stream events. The bytes of
  # a character still in flight stay pending; everything else is made valid
  # before it can reach a durable note or a renderer's regex.
  defp drain(buffer, mode, now) do
    {ready, tail} = split_incomplete_tail(buffer.pending)
    ready = String.replace_invalid(ready)

    {chunks, rest} =
      case mode do
        :final -> take_chunks(ready <> String.replace_invalid(tail), buffer.chunk_bytes, true)
        :latency -> take_chunks(ready, buffer.chunk_bytes, true)
        :size -> take_chunks(ready, buffer.chunk_bytes, false)
      end

    pending = if(mode == :final, do: rest, else: rest <> tail)
    {chunks, %{buffer | pending: pending, started_at: if(pending == "", do: nil, else: now)}}
  end

  defp take_chunks("", _chunk_bytes, _all?), do: {[], ""}

  defp take_chunks(value, chunk_bytes, all?) do
    if all? or byte_size(value) >= chunk_bytes do
      chunk =
        case truncate_utf8(value, min(byte_size(value), chunk_bytes)) do
          "" -> value |> String.next_grapheme() |> elem(0)
          prefix -> prefix
        end

      rest = binary_part(value, byte_size(chunk), byte_size(value) - byte_size(chunk))
      {chunks, rest} = take_chunks(rest, chunk_bytes, all?)
      {[chunk | chunks], rest}
    else
      {[], value}
    end
  end

  # A trailing lead byte with too few continuation bytes is a character whose
  # remaining bytes have not arrived yet. At most three bytes can be pending.
  defp split_incomplete_tail(binary) do
    size = byte_size(binary)

    Enum.find_value(1..min(3, size)//1, {binary, ""}, fn back ->
      <<head::binary-size(size - back), lead, continuation::binary>> = binary

      if incomplete_sequence?(lead, continuation),
        do: {head, binary_part(binary, size - back, back)}
    end)
  end

  defp incomplete_sequence?(lead, continuation) do
    needed =
      cond do
        lead in 0xC2..0xDF -> 2
        lead in 0xE0..0xEF -> 3
        lead in 0xF0..0xF4 -> 4
        true -> 0
      end

    needed > byte_size(continuation) + 1 and
      continuation |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x80..0xBF))
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value) do
      value
    else
      trim_invalid_suffix(binary_part(value, 0, byte_size(value) - 1))
    end
  end
end
