defmodule ReyCode.Tool.Grep do
  @moduledoc "Searches file contents for a pattern within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @max_matches Application.compile_env(:rey_code, :tool_grep_max_matches, 1_000)
  @max_file_bytes Application.compile_env(:rey_code, :tool_grep_max_file_bytes, 512_000)

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    pattern = Support.arg(arguments, :pattern)
    path = Support.arg(arguments, :path)

    with :ok <- Support.require_present(pattern, :missing_pattern),
         :ok <- Support.require_present(path, :missing_path),
         {:ok, regex} <- compile_pattern(pattern),
         {:ok, canonical} <- Support.within_roots(path, request) do
      search(canonical, regex)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp search(canonical, regex) do
    files = Path.wildcard(Path.join(canonical, "**/*"), match_dot: true)
    {matches, _stopped} = Enum.reduce_while(files, {[], false}, &visit_file(&1, &2, regex))
    Result.ok(Enum.join(matches, "\n"))
  end

  defp visit_file(file, {acc, _stopped}, regex) do
    if File.regular?(file) do
      scan_file(file, regex, acc)
    else
      {:cont, {acc, false}}
    end
  end

  defp scan_file(file, regex, acc) do
    case File.read(file) do
      {:ok, content} when byte_size(content) <= @max_file_bytes ->
        case append_matches(content, regex, acc, file) do
          {:halt, matches} -> {:halt, {matches, true}}
          {:cont, matches} -> {:cont, {matches, false}}
        end

      _other ->
        {:cont, {acc, false}}
    end
  end

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _reason} -> {:error, :invalid_pattern}
    end
  end

  defp append_matches(content, regex, acc, file) do
    new_lines =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {line, number}, lines ->
        if Regex.match?(regex, line) do
          ["#{file}:#{number}:#{line}" | lines]
        else
          lines
        end
      end)

    combined = Enum.reverse(new_lines) ++ acc

    if length(combined) >= @max_matches do
      {:halt, Enum.take(combined, @max_matches)}
    else
      {:cont, combined}
    end
  end
end
