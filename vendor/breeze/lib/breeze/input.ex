defmodule Breeze.Input do
  @moduledoc false

  @mouse_prefix "\e[<"

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

  A fast wheel or drag delivers several SGR mouse reports in one read. Decoding
  the chunk as a single key would fail mouse decoding and fall through to the
  raw text, which a text input would then insert verbatim.
  """
  def decode_all(@mouse_prefix <> _ = raw) do
    raw
    |> String.split(@mouse_prefix, trim: true)
    |> Enum.map(&decode(@mouse_prefix <> &1))
  end

  def decode_all(raw), do: [decode(raw)]

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
