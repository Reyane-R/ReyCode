defmodule Breeze.Input do
  @moduledoc false

  def decode(raw_key) do
    case Breeze.Mouse.decode(raw_key) do
      {:ok, event} ->
        {:mouse, event}

      :error ->
        {:key, decode_key(raw_key)}
    end
  end

  @doc """
  Decodes one reader chunk into every event it carries.

  A fast wheel or drag delivers several escape sequences in one read, possibly
  behind typed text. Decoding the chunk as a single key would fail and fall
  through to raw text, which a text input would then insert verbatim.
  """
  def decode_all(""), do: []

  def decode_all(raw) do
    case String.split(raw, "\e") do
      [only] ->
        [decode(only)]

      [head | sequences] ->
        prefix = if head == "", do: [], else: [decode(head)]
        prefix ++ Enum.map(sequences, &decode("\e" <> &1))
    end
  end

  @doc """
  Splits a chunk into the bytes that can be decoded now and a trailing
  incomplete escape sequence to hold for the next read.

  A terminal may split one mouse report across two reads. Decoding the first
  half alone yields a bare Escape, which applications treat as a cancel key.
  A lone trailing ESC is held too; the caller flushes it after a short delay
  so the real Escape key still arrives.
  """
  def split_complete(data) do
    case last_escape_index(data) do
      nil ->
        {data, ""}

      index ->
        {head, tail} = String.split_at(data, index)
        if complete_sequence?(tail), do: {data, ""}, else: {head, tail}
    end
  end

  defp last_escape_index(data) do
    data
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {glyph, index}, last -> if glyph == "\e", do: index, else: last end)
  end

  defp complete_sequence?("\e"), do: false
  defp complete_sequence?("\e["), do: false
  defp complete_sequence?("\eO"), do: false
  defp complete_sequence?("\e[" <> rest), do: csi_terminated?(rest)
  defp complete_sequence?(_other), do: true

  # CSI parameters (0x30-0x3F) and intermediates (0x20-0x2F) run until a final
  # byte (0x40-0x7E). Anything else is malformed; let the decoder judge it.
  defp csi_terminated?(<<byte, _rest::binary>>) when byte in 0x40..0x7E, do: true
  defp csi_terminated?(<<byte, rest::binary>>) when byte in 0x20..0x3F, do: csi_terminated?(rest)
  defp csi_terminated?(<<_byte, _rest::binary>>), do: true
  defp csi_terminated?(""), do: false

  defp decode_key(raw_key) when is_binary(raw_key) do
    if printable_text?(raw_key) and String.length(raw_key) > 1 do
      %{"key" => raw_key, "__batched_printable__" => true}
    else
      Breeze.KeyDecoder.decode(raw_key)
    end
  end

  defp decode_key(raw_key), do: Breeze.KeyDecoder.decode(raw_key)

  defp printable_text?(raw_key), do: Breeze.Printable.text?(raw_key)
end
