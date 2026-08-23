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

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result, Support}

  @defaults [max_matches: 1_000, max_file_bytes: 512_000, max_files: 10_000, timeout_ms: 10_000]

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    limits = limits(Keyword.fetch!(opts, :policy))

    with {:ok, pattern} <- Support.require_arg(arguments, :pattern),
         :ok <- Support.require_present(pattern, :missing_pattern),
         {:ok, path} <- Support.require_arg(arguments, :path),
         {:ok, regex} <- compile_pattern(pattern),
         {:ok, canonical} <- Support.within_roots(path, request) do
      search(canonical, regex, limits)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp search(root, regex, limits) do
    acc = %{lines: [], matches: 0, files: 0, binary: 0, skipped: 0, truncated?: false}

    case File.lstat(root) do
      {:ok, %File.Stat{type: :regular}} -> respond(scan_file(root, regex, acc, limits))
      {:ok, %File.Stat{type: :directory}} -> respond(walk(root, regex, acc, limits))
      {:ok, _other} -> Result.error(:unsupported_file_type)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp respond(acc) do
    Result.ok(Enum.reverse(acc.lines) |> Enum.join("\n"),
      truncated: acc.truncated?,
      metadata: %{
        "matches" => acc.matches,
        "files_scanned" => acc.files,
        "binary_files_skipped" => acc.binary,
        "files_skipped" => acc.skipped
      }
    )
  end

  # Depth-first walk that refuses to descend into symlinks, so a link out of
  # the workspace can never widen what is scanned.
  defp walk(_dir, _regex, %{truncated?: true} = acc, _limits), do: acc

  defp walk(dir, regex, acc, limits) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(
          Enum.sort(entries),
          acc,
          &walk_entry(&1, &2, dir, regex, limits)
        )

      {:error, _reason} ->
        %{acc | skipped: acc.skipped + 1}
    end
  end

  defp walk_entry(entry, acc, dir, regex, limits) do
    next = visit(Path.join(dir, entry), regex, acc, limits)
    if next.truncated?, do: {:halt, next}, else: {:cont, next}
  end

  defp visit(path, regex, acc, limits) do
    cond do
      acc.files >= limits.max_files ->
        %{acc | truncated?: true}

      System.monotonic_time(:millisecond) > limits.deadline ->
        %{acc | truncated?: true}

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            scan_file(path, regex, acc, limits)

          {:ok, %File.Stat{type: :directory}} ->
            walk(path, regex, acc, limits)

          _other ->
            %{acc | skipped: acc.skipped + 1}
        end
    end
  end

  defp scan_file(path, regex, acc, limits) do
    with {:ok, %File.Stat{size: size}} when size <= limits.max_file_bytes <- File.stat(path),
         {:ok, content} <- File.read(path) do
      if String.contains?(content, <<0>>) do
        %{acc | binary: acc.binary + 1}
      else
        append_matches(content, regex, path, %{acc | files: acc.files + 1}, limits)
      end
    else
      _other -> %{acc | skipped: acc.skipped + 1}
    end
  end

  defp append_matches(content, regex, path, acc, limits) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while(acc, fn {line, number}, acc ->
      match_line(line, number, regex, path, acc, limits)
    end)
  end

  defp match_line(line, number, regex, path, acc, limits) do
    if Regex.match?(regex, line) do
      record_match(line, number, path, acc, limits)
    else
      {:cont, acc}
    end
  end

  defp record_match(line, number, path, acc, limits) do
    matches = acc.matches + 1

    if matches > limits.max_matches do
      {:halt, %{acc | truncated?: true}}
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

  defp limits(policy) do
    %{
      max_matches: RuntimeConfig.policy(policy, :tool_grep_max_matches, @defaults[:max_matches]),
      max_file_bytes:
        RuntimeConfig.policy(policy, :tool_grep_max_file_bytes, @defaults[:max_file_bytes]),
      max_files: RuntimeConfig.policy(policy, :tool_grep_max_files, @defaults[:max_files]),
      deadline:
        System.monotonic_time(:millisecond) +
          RuntimeConfig.policy(policy, :tool_grep_timeout_ms, @defaults[:timeout_ms])
    }
  end
end
