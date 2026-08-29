defmodule ReyCode.Tool.DiffPreviewTest do
  use ExUnit.Case, async: true

  alias ReyCode.Tool.DiffPreview

  test "edits join per-patch anchors with before and after fragments" do
    preview =
      DiffPreview.edits([%{old: "alpha", new: "ALPHA"}, %{old: "omega", new: "OMEGA"}])

    assert preview == %{
             "lines" => [
               "@@ patch 1 @@",
               "-alpha",
               "+ALPHA",
               "@@ patch 2 @@",
               "-omega",
               "+OMEGA"
             ],
             "truncated" => false
           }
  end

  test "write marks created, unavailable, and replaced prior content" do
    assert DiffPreview.write(:missing, "hi") == %{
             "lines" => ["@@ created @@", "+hi"],
             "truncated" => false
           }

    assert DiffPreview.write(:unavailable, "hi") == %{
             "lines" => ["@@ previous content unavailable @@", "+hi"],
             "truncated" => true
           }

    assert DiffPreview.write("old", "new") == %{
             "lines" => ["@@ previous @@", "-old", "@@ replacement @@", "+new"],
             "truncated" => false
           }
  end

  test "fragments truncate at the line cap" do
    lines = Enum.map_join(1..30, "\n", &"line-#{&1}")
    %{"lines" => preview_lines, "truncated" => truncated?} = DiffPreview.write(:missing, lines)

    assert length(preview_lines) == 20
    assert Enum.at(preview_lines, 1) == "+line-1"
    assert truncated?
  end

  test "a final line without a newline is kept without a truncation marker" do
    %{"lines" => preview_lines, "truncated" => truncated?} =
      DiffPreview.write(:missing, "only-line")

    assert preview_lines == ["@@ created @@", "+only-line"]
    refute truncated?
  end
end
