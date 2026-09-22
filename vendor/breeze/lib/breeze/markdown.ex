defmodule Breeze.Markdown do
  @moduledoc false

  alias BackBreeze.TextSpan

  import BackBreeze.Utils, only: [string_length: 1]

  @reset "\e[0m"
  @code "\e[38;5;223m"
  @bold "\e[1m"
  @bullets [?*, ?-, ?+]

  def render(doc, width) do
    doc
    |> render_ansi(width, "\n")
    |> spans_from_ansi()
  end

  @doc "Rendered lines with explicit copy separators: a space for wrapping, newline for structural breaks."
  def render_lines(doc, width) do
    marker = soft_break(doc)

    doc
    |> render_ansi(width, marker)
    |> String.split(Regex.compile!("(\\n|#{Regex.escape(marker)})"),
      include_captures: true,
      trim: false
    )
    |> Enum.chunk_every(2)
    |> Enum.map_reduce(false, &copy_line(&1, &2, marker))
    |> elem(0)
  end

  defp copy_line([text | tail], continued?, marker) do
    separator =
      case tail do
        [^marker] -> " "
        ["\n"] -> "\n"
        [] -> ""
      end

    skip =
      if continued?,
        do: String.length(text) - String.length(String.trim_leading(text, " ")),
        else: 0

    {%{spans: line_spans(text), separator: separator, copy_skip: skip, code?: code_line?(text)},
     separator == " "}
  end

  defp code_line?(@code <> "    " <> _code), do: true
  defp code_line?(_text), do: false

  defp line_spans(@code <> "    " <> code), do: spans_from_ansi(@code <> code)
  defp line_spans(text), do: spans_from_ansi(text)

  defp soft_break(doc) do
    present =
      Regex.scan(~r/\x{E000}(\d+)\x{E001}/u, doc, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    id = Enum.find(0..MapSet.size(present), &(not MapSet.member?(present, Integer.to_string(&1))))
    "\u{E000}#{id}\u{E001}"
  end

  defp render_ansi(doc, width, soft_break) do
    doc
    |> String.split(["\r\n", "\n"], trim: false)
    |> Enum.map(&String.trim_trailing/1)
    |> process([], "", {width, soft_break})
    |> String.trim_trailing("\n")
  end

  defp process([], text, indent, width), do: write_text(text, indent, width)

  defp process(["" | rest], text, indent, width) do
    write_text(text, indent, width) <> process(rest, [], indent, width)
  end

  defp process(["#" <> _ = heading | rest], text, indent, width) do
    write_text(text, indent, width) <>
      write_heading(heading, width) <>
      process(rest, [], "", width)
  end

  defp process(["```" <> _ | rest], text, indent, width) do
    write_text(text, indent, width) <> process_fenced_code(rest, [], indent, width)
  end

  defp process(["    " <> line | rest], text, indent, width) do
    write_text(text, indent, width) <>
      process_indented_code(rest, [line], indent, width)
  end

  defp process([<<bullet, ?\s, item::binary>> | rest], text, indent, width)
       when bullet in @bullets do
    write_text(text, indent, width) <> process_list("• ", item, rest, indent, width)
  end

  defp process([line | rest], text, indent, width) do
    process(rest, [line | text], indent, width)
  end

  defp write_heading(heading, {width, soft_break}) do
    heading
    |> String.replace(~r/^#+\s*/, "")
    |> handle_heading_inline()
    |> String.split()
    |> wrap_words(width)
    |> Enum.map(&(@bold <> &1 <> @reset))
    |> Enum.join(soft_break)
    |> Kernel.<>("\n\n")
  end

  defp process_fenced_code(["```" <> _ | rest], code, indent, width) do
    write_code_block(Enum.reverse(code)) <> process(rest, [], indent, width)
  end

  defp process_fenced_code([line | rest], code, indent, width) do
    process_fenced_code(rest, [line | code], indent, width)
  end

  defp process_fenced_code([], code, _indent, _width) do
    write_code_block(Enum.reverse(code))
  end

  defp process_indented_code(["    " <> line | rest], code, indent, width) do
    process_indented_code(rest, [line | code], indent, width)
  end

  defp process_indented_code(rest, code, indent, width) do
    write_code_block(Enum.reverse(code)) <> process(rest, [], indent, width)
  end

  defp write_code_block(lines) do
    lines
    |> Enum.map(&(@code <> "    " <> &1 <> @reset))
    |> Enum.join("\n")
    |> Kernel.<>("\n\n")
  end

  defp process_list(prefix, item, rest, indent, {width, soft_break} = layout) do
    available = width - string_length(indent) - string_length(prefix)
    continuation = String.duplicate(" ", string_length(prefix))
    words = item |> handle_inline() |> String.split()
    [first | more] = wrap_words(words, available)
    lines = [indent <> prefix <> first | Enum.map(more, &(indent <> continuation <> &1))]
    result = Enum.join(lines, soft_break) <> "\n"

    case rest do
      [<<b, ?\s, _::binary>> | _] when b in @bullets ->
        result <> process(rest, [], indent, layout)

      _ ->
        result <> "\n" <> process(rest, [], indent, layout)
    end
  end

  defp write_text([], _indent, _width), do: ""

  defp write_text(text_lines, indent, {width, soft_break}) do
    available = width - string_length(indent)

    text_lines
    |> Enum.reverse()
    |> Enum.join(" ")
    |> handle_inline()
    |> String.split()
    |> wrap_words(available)
    |> Enum.map(&(indent <> &1))
    |> Enum.join(soft_break)
    |> Kernel.<>("\n\n")
  end

  defp wrap_words([], _width), do: [""]

  defp wrap_words(words, width) do
    {lines, current} =
      Enum.reduce(words, {[], ""}, fn word, {lines, current} ->
        if current == "" do
          {lines, word}
        else
          candidate = current <> " " <> word

          if string_length(candidate) <= width do
            {lines, candidate}
          else
            {[current | lines], word}
          end
        end
      end)

    [current | lines] |> Enum.reverse()
  end

  defp handle_inline(text) do
    text
    |> remove_links()
    |> apply_inline(~r/`([^`]+)`/, @code)
    |> apply_inline(~r/\*\*(.+?)\*\*/, @bold)
  end

  defp handle_heading_inline(text) do
    text
    |> remove_links()
    |> remove_inline(~r/`([^`]+)`/)
    |> remove_inline(~r/\*\*(.+?)\*\*/)
  end

  defp apply_inline(text, pattern, color) do
    Regex.replace(pattern, text, fn _, inner -> color <> inner <> @reset end)
  end

  defp remove_inline(text, pattern), do: Regex.replace(pattern, text, "\\1")

  defp remove_links(text) do
    Regex.replace(~r{\[([^\]]*?)\]\((.*?)\)}, text, "\\1 (\\2)")
  end

  defp spans_from_ansi(text) do
    ~r/(\e\[[0-9;]*m)/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.reduce({[], %{}}, fn
      @reset, {spans, _style} ->
        {spans, %{}}

      @code, {spans, style} ->
        {spans, Map.put(style, :foreground_color, "#E9DCC0")}

      @bold, {spans, style} ->
        {spans, Map.put(style, :bold, true)}

      content, {spans, style} ->
        {[TextSpan.new(content, style) | spans], style}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
