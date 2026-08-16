defmodule Quality.ScannerDetectionTest do
  use ExUnit.Case, async: true

  alias ReyCode.QualityScanner

  @tag :tmp_dir
  test "scan reports matching line numbers and trimmed content", %{tmp_dir: tmp_dir} do
    file = write_fixture(tmp_dir, "unsafe.ex", "first\n  String.to_atom(input)  \nlast\n")

    assert QualityScanner.scan(~r/String\.to_atom/, files: [file]) == [
             %{file: file, line: 2, content: "String.to_atom(input)"}
           ]
  end

  @tag :tmp_dir
  test "scan ignores non-matching lines", %{tmp_dir: tmp_dir} do
    file = write_fixture(tmp_dir, "safe.ex", "String.to_existing_atom(input)\n")

    assert QualityScanner.scan(~r/String\.to_atom/, files: [file]) == []
  end

  @tag :tmp_dir
  test "scan excludes files by path substring", %{tmp_dir: tmp_dir} do
    included = write_fixture(tmp_dir, "included.ex", "Process.sleep(10)\n")
    excluded = write_fixture(tmp_dir, "simulator.ex", "Process.sleep(20)\n")

    assert QualityScanner.scan(~r/Process\.sleep/,
             files: [included, excluded],
             exclude: ["simulator.ex"]
           ) == [%{file: included, line: 1, content: "Process.sleep(10)"}]
  end

  test "format_matches produces assertion-ready locations" do
    matches = [
      %{file: "lib/example.ex", line: 12, content: "String.to_atom(value)"},
      %{file: "lib/other.ex", line: 7, content: "Process.sleep(1_000)"}
    ]

    assert QualityScanner.format_matches(matches) ==
             "  lib/example.ex:12  String.to_atom(value)\n" <>
               "  lib/other.ex:7  Process.sleep(1_000)"
  end

  test "code_files returns sorted production Elixir files only" do
    files = QualityScanner.code_files()

    assert files == Enum.sort(files)
    assert "lib/rey_code/event.ex" in files
    assert Enum.all?(files, &String.starts_with?(&1, "lib/"))
    assert Enum.all?(files, &(Path.extname(&1) in [".ex", ".exs"]))
  end

  defp write_fixture(tmp_dir, name, content) do
    path = Path.join(tmp_dir, name)
    File.write!(path, content)
    path
  end
end
