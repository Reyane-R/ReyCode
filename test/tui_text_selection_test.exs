defmodule ReyCode.TUI.TextSelectionTest do
  use ExUnit.Case, async: true

  alias BackBreeze.{TextSpan, Ucwidth}
  alias ReyCode.TUI.TextSelection

  test "soft wrapping and long code preserve logical newlines and indentation on copy" do
    prose = "alpha beta gamma delta epsilon"
    rows = rows(prose, 10)
    assert copy_all(rows) == prose
    assert "- alpha beta gamma delta" |> rows(10) |> copy_all() == "• alpha beta gamma delta"

    code = "```elixir\nif ready do\n  世界abcdefghi()\nend\n```"
    rows = rows(code, 8)

    assert Enum.all?(rows, fn row ->
             Enum.sum(Enum.map(String.graphemes(row.text), &Ucwidth.width/1)) <= 8
           end)

    assert copy_all(rows) == "if ready do\n  世界abcdefghi()\nend"
  end

  test "backward selections preserve Unicode graphemes and apply the same highlight range" do
    spans = [%TextSpan{text: "a界éz", style: %{bold: true}}]
    rows = [%{id: "selection-m-0", text: "a界éz", spans: spans, separator: ""}]
    selection = %TextSelection{anchor: {0, 3}, endpoint: {0, 1}, rows: rows}
    assert TextSelection.text(selection) == "界é"
    [line] = TextSelection.decorate(rows, "m", selection)
    assert Enum.map(line.spans, &Map.get(&1.style, :reverse, false)) == [false, true, true, false]
    assert Enum.all?(line.spans, & &1.style.bold)
  end

  test "cross-message copy has separators but no author labels or controls" do
    selection = %TextSelection{
      anchor: {0, 1},
      endpoint: {1, 2},
      rows: [
        %{text: "first", separator: "\n\n"},
        %{text: "second", separator: ""}
      ]
    }

    assert TextSelection.text(selection) == "irst\n\nse"
    assert TextSelection.text(%{selection | endpoint: selection.anchor}) == ""
  end

  test "private Unicode characters cannot collide with wrap markers" do
    text = "hello \u{E000}0\u{E001} \u{E000}1\u{E001} world"
    assert text |> rows(12) |> copy_all() == text
  end

  test "Markdown headings stay readable around inline code" do
    [heading, blank, subheading] =
      Breeze.Markdown.render_lines(
        "## The pipeline\n\n### 1. CLI (`src/cli.ts`, ~50 lines)",
        80
      )

    assert Enum.map_join(heading.spans, & &1.text) == "The pipeline"
    assert blank.spans == []
    assert Enum.map_join(subheading.spans, & &1.text) == "1. CLI (src/cli.ts, ~50 lines)"

    for row <- [heading, subheading], span <- row.spans do
      assert span.style.bold
      refute Map.has_key?(span.style, :background_color)
      refute Map.has_key?(span.style, :foreground_color)
    end
  end

  test "wrapped Markdown headings keep one readable style and copy as prose" do
    rows = Breeze.Markdown.render_lines("### Project discovery (`src/project.ts`)", 18)

    assert Enum.map_join(rows, fn row ->
             Enum.map_join(row.spans, & &1.text) <> row.separator
           end) == "Project discovery (src/project.ts)"

    assert length(rows) > 1

    assert Enum.all?(rows, fn row ->
             Enum.all?(row.spans, &(&1.style == %{bold: true}))
           end)
  end

  test "missing and obsolete edge timers do not change the view" do
    term = %{assigns: %{text_selection: nil}}
    assert TextSelection.tick(term, make_ref()) == term
  end

  defp rows(source, width) do
    source
    |> Breeze.Markdown.render_lines(width)
    |> TextSelection.wrap_lines(width)
    |> Enum.map(fn row -> Map.put(row, :text, Enum.map_join(row.spans, & &1.text)) end)
  end

  defp copy_all(rows) do
    last = List.last(rows)

    TextSelection.text(%TextSelection{
      rows: rows,
      anchor: {0, 0},
      endpoint: {length(rows) - 1, String.length(last.text)}
    })
  end
end
