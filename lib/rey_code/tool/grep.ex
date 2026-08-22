defmodule ReyCode.Tool.Grep do
  @moduledoc """
  Searches file contents for a pattern within the trusted roots.

  Traversal never follows symlinks and only scans regular files reached
  without one; files containing null bytes are skipped as binary rather than
  garbled. Match counts, scanned-file counts, and skipped-binary counts are
  reported in metadata, with `truncated` set when the match cap cut the
  search short.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @defaults [max_matches: 1_000, max_file_bytes: 512_000]

  defp max_matches,
    do: Application.get_env(:rey_code, :tool_grep_max_matches, @defaults[:max_matches])

  defp max_file_bytes,
    do: Application.get_env(:rey_code, :tool_grep_max_file_bytes, @defaults[:max_file_bytes])

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    pattern = Support.arg(arguments, :pattern)
    path = Support.arg(arguments, :path)

    with :ok <- Support.require_present(pattern, :missing_pattern),
         {:ok, regex} <- compile_pattern(pattern),
         {:ok, canonical} <- Support.within_roots(path, request) do
      search(canonical, regex)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp search(root, regex) do
    acc = %{lines: [], matches: 0, files: 0, binary: 0, truncated?: false}

    acc =
      case File.lstat(root) do
        {:ok, %File.Stat{type: :regular}} -> scan_file(root, regex, acc)
        _other -> walk(root, regex, acc)
      end

    Result.ok(Enum.reverse(acc.lines) |> Enum.join("\n"),
      truncated: acc.truncated?,
      metadata: %{
        "matches" => acc.matches,
        "files_scanned" => acc.files,
        "binary_files_skipped" => acc.binary
      }
    )
  end

  # Depth-first walk that refuses to descend into symlinks, so a link out of
  # the workspace can never widen what is scanned.
  defp walk(dir, regex, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(Enum.sort(entries), acc, fn entry, acc ->
          visit(Path.join(dir, entry), regex, acc)
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp visit(path, regex, acc) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        scan_file(path, regex, acc)

      {:ok, %File.Stat{type: :directory}} ->
        walk(path, regex, acc)

      _other ->
        acc
    end
  end

  defp scan_file(path, regex, acc) do
    cap = max_file_bytes()

    case File.read(path) do
      {:ok, content} when byte_size(content) <= cap ->
        if String.contains?(content, <<0>>) do
          %{acc | binary: acc.binary + 1}
        else
          append_matches(content, regex, path, %{acc | files: acc.files + 1})
        end

      _other ->
        acc
    end
  end

  defp append_matches(content, regex, path, acc) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while(acc, fn {line, number}, acc ->
      match_line(line, number, regex, path, acc)
    end)
  end

  defp match_line(line, number, regex, path, acc) do
    if Regex.match?(regex, line) do
      record_match(line, number, path, acc)
    else
      {:cont, acc}
    end
  end

  defp record_match(line, number, path, acc) do
    matches = acc.matches + 1

    if matches > max_matches() do
      {:halt, %{acc | matches: matches, truncated?: true}}
    else
      {:cont, %{acc | matches: matches, lines: ["#{path}:#{number}:#{line}" | acc.lines]}}
    end
  end

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _reason} -> {:error, :invalid_pattern}
    end
  end
end
