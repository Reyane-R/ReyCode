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
        drain(buffer, true, now)

      byte_size(buffer.pending) >= buffer.chunk_bytes ->
        drain(buffer, buffer.flush_tail_on_size?, now)

      true ->
        {[], buffer}
    end
  end

  @doc "Emits all pending text as UTF-8-safe chunks."
  @spec flush(t(), integer()) :: {[binary()], t()}
  def flush(buffer, now \\ System.monotonic_time(:millisecond)) do
    drain(buffer, true, now)
  end

  @doc "Returns the absolute monotonic deadline for pending text, or nil when empty."
  @spec next_flush_deadline(t()) :: integer() | nil
  def next_flush_deadline(%__MODULE__{pending: ""}), do: nil

  def next_flush_deadline(%__MODULE__{started_at: started_at, chunk_latency_ms: latency})
      when is_integer(started_at),
      do: started_at + latency

  @doc "Flushes pending text only when its latency deadline has been reached."
  @spec flush_due(t(), integer()) :: {[binary()], t()}
  def flush_due(buffer, now \\ System.monotonic_time(:millisecond)) do
    case next_flush_deadline(buffer) do
      deadline when is_integer(deadline) and now >= deadline -> flush(buffer, now)
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

  defp drain(%{pending: ""} = buffer, _force, _now), do: {[], %{buffer | started_at: nil}}

  defp drain(buffer, force, now) do
    if force or byte_size(buffer.pending) >= buffer.chunk_bytes do
      {chunk, buffer} = take_chunk(buffer, now)
      {rest, buffer} = drain(buffer, force, now)
      {[chunk | rest], buffer}
    else
      {[], buffer}
    end
  end

  defp take_chunk(buffer, now) do
    size = min(byte_size(buffer.pending), buffer.chunk_bytes)

    chunk =
      case truncate_utf8(buffer.pending, size) do
        "" -> buffer.pending |> String.next_grapheme() |> elem(0)
        value -> value
      end

    rest =
      binary_part(
        buffer.pending,
        byte_size(chunk),
        byte_size(buffer.pending) - byte_size(chunk)
      )

    next = %{buffer | pending: rest, started_at: if(rest == "", do: nil, else: now)}
    {chunk, next}
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value) do
      value
    else
      trim_invalid_suffix(binary_part(value, 0, byte_size(value) - 1))
    end
  end
end
