defmodule ReyCode.Tool.DiffPreview do
  @moduledoc """
  Builds bounded, JSON-safe before/after fragments for terminal presentation.

  This is intentionally not a full diff algorithm. Edit previews show the exact
  replacement anchors and Write previews show bounded previous/replacement
  blocks, preserving truth without quadratic line comparison.
  """

  @max_line_count 20
  @max_bytes 8_192

  @type t :: %{required(String.t()) => [String.t()] | boolean()}

  @doc "Builds fragments for an Edit request's validated patches."
  @spec edits([%{required(:old) => String.t(), required(:new) => String.t()}]) :: t()
  def edits(patches) do
    patches
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {patch, index} ->
      ["@@ patch #{index} @@"] ++ prefixed_lines(patch.old, "-") ++ prefixed_lines(patch.new, "+")
    end)
    |> bound()
  end

  @doc "Builds fragments for a Write request and its bounded prior content."
  @spec write(String.t() | :missing | :unavailable, String.t()) :: t()
  def write(:missing, content), do: bound(["@@ created @@"] ++ prefixed_lines(content, "+"))

  def write(:unavailable, content) do
    (["@@ previous content unavailable @@"] ++ prefixed_lines(content, "+"))
    |> bound(true)
  end

  def write(previous, content) when is_binary(previous) do
    (["@@ previous @@"] ++
       prefixed_lines(previous, "-") ++ ["@@ replacement @@"] ++ prefixed_lines(content, "+"))
    |> bound()
  end

  defp prefixed_lines(content, prefix) do
    {lines, truncated?} = take_lines(content, @max_line_count + 1)
    lines = Enum.map(lines, &(prefix <> &1))
    if truncated?, do: lines ++ [prefix <> "…"], else: lines
  end

  defp take_lines(content, limit), do: take_lines(content, limit, [])
  defp take_lines(_content, 0, lines), do: {Enum.reverse(lines), true}

  defp take_lines(content, limit, lines) do
    case :binary.match(content, "\n") do
      {index, 1} ->
        line = binary_part(content, 0, index)
        rest_start = index + 1
        rest = binary_part(content, rest_start, byte_size(content) - rest_start)
        take_lines(rest, limit - 1, [line | lines])

      :nomatch ->
        {Enum.reverse([content | lines]), false}
    end
  end

  defp bound(lines, already_truncated? \\ false) do
    {kept, _bytes, kept_count, truncated?} =
      Enum.reduce_while(lines, {[], 0, 0, already_truncated?}, fn line,
                                                                  {kept, bytes, count, truncated?} ->
        next_bytes = bytes + byte_size(line)

        if count >= @max_line_count or next_bytes > @max_bytes do
          {:halt, {kept, bytes, count, true}}
        else
          {:cont, {[line | kept], next_bytes, count + 1, truncated?}}
        end
      end)

    %{"lines" => Enum.reverse(kept), "truncated" => truncated? or kept_count < length(lines)}
  end
end
