defmodule ReyCode.ExportMixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReyCode.Export
  alias ReyCode.Orchestration.Engine

  test "exports an explicitly selected Session as Markdown and HTML" do
    projection = Engine.snapshot()
    session_id = List.last(projection.session_order)

    root =
      Path.join(
        System.tmp_dir!(),
        "rey-code-export-task-#{System.unique_integer([:positive])}"
      )

    markdown = Path.join(root, "session.md")
    html = Path.join(root, "session.html")
    on_exit(fn -> File.rm_rf!(root) end)

    assert capture_export([
             "--session",
             session_id,
             "--format",
             "markdown",
             "--output",
             markdown
           ]) =~ "Exported #{session_id}"

    assert File.read!(markdown) =~ "Session: `#{session_id}`"

    assert capture_export([
             "--session",
             session_id,
             "--format",
             "html",
             "--output",
             html
           ]) =~ "Exported #{session_id}"

    assert File.read!(html) =~ "<!doctype html>"
  end

  test "rejects unsupported formats and missing Sessions" do
    assert_raise Mix.Error, ~r/Unsupported export format/, fn ->
      capture_export(["--format", "pdf"])
    end

    assert_raise Mix.Error, ~r/Session not found/, fn ->
      capture_export(["--session", "missing-session"])
    end
  end

  defp capture_export(args) do
    Mix.Task.reenable("rey_code.export")
    capture_io(fn -> Export.run(args) end)
  end
end
