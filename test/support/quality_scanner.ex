defmodule ReyCode.QualityScanner do
  @moduledoc """
  Utilities for scanning source files for anti-patterns.

  Used by guardian tests in `test/quality/`.
  """

  @lib_dir "lib"

  @doc "Returns all `.ex` and `.exs` files under lib/."
  def code_files do
    (Path.wildcard("#{@lib_dir}/**/*.ex") ++ Path.wildcard("#{@lib_dir}/**/*.exs"))
    |> Enum.sort()
  end

  @doc """
  Scans the given files for a regex pattern.

  Returns a list of `%{file: path, line: line_number, content: line_content}`.

  ## Options

    * `:files` — list of files to scan (default: `code_files/0`)
    * `:exclude` — list of substrings; files whose path contains any of them are skipped
  """
  def scan(pattern, opts \\ []) do
    files = Keyword.get(opts, :files) || code_files()
    exclude = Keyword.get(opts, :exclude, [])

    for file <- files,
        not excluded?(file, exclude),
        File.regular?(file),
        {content, index} <- lines_with_index(file),
        Regex.match?(pattern, content) do
      %{file: file, line: index + 1, content: String.trim(content)}
    end
  end

  @doc "Formats a list of matches for readable assertion error messages."
  def format_matches(matches) do
    Enum.map_join(matches, "\n", fn %{file: f, line: l, content: c} -> "  #{f}:#{l}  #{c}" end)
  end

  defp lines_with_index(file) do
    file
    |> File.read!()
    |> String.split("\n", trim: false)
    |> Enum.with_index()
  end

  defp excluded?(file, exclude) do
    Enum.any?(exclude, &String.contains?(file, &1))
  end
end
