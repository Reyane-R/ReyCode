defmodule ReyCode.Tool.Read do
  @moduledoc """
  Reads a bounded, line-oriented slice of a UTF-8 text file within the
  trusted roots.

  `offset` (1-based line number) and `limit` bound every read, so large files
  are consumed in windows instead of failing wholesale. Lines are assembled
  from fixed-size chunks and an unterminated line is cut at the remaining
  byte budget, so a pathological single-line file can never balloon the node.
  The result reports the returned range in its metadata and sets `truncated`
  when more content lies beyond the window. Binary files are rejected instead
  of garbled.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result, Support}

  @chunk_bytes 64_000
  @defaults [max_bytes: 512_000, max_lines: 2_000]

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    limits = limits(Keyword.fetch!(opts, :policy))

    with {:ok, canonical} <- Support.require_path(arguments, :path, request),
         {:ok, offset} <- window(arguments, :offset, 1, 1, :invalid_offset),
         {:ok, limit} <- window(arguments, :limit, limits.max_lines, 0, :invalid_limit) do
      open_window(canonical, offset, limit, limits.max_bytes)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp window(arguments, key, default, minimum, error) do
    case Support.integer_arg(arguments, key, default) do
      {:ok, value} when value >= minimum -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp open_window(canonical, offset, limit, max_bytes) do
    case File.open(canonical, [:read, :binary]) do
      {:ok, device} ->
        try do
          collect(device, "", offset, limit, 1, [], 0, max_bytes)
        after
          File.close(device)
        end

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp collect(device, buffer, offset, remaining, _line_no, lines, bytes, max_bytes)
       when remaining <= 0 or bytes >= max_bytes,
       do: finish(lines, offset, more_content?(device, buffer))

  # Lines before the window are located, not retained: a newline is one byte,
  # so a chunk that lacks one can be discarded wholesale.
  defp collect(device, buffer, offset, remaining, line_no, lines, bytes, max_bytes)
       when line_no < offset do
    case skip_line(device, buffer) do
      {:ok, rest} ->
        collect(device, rest, offset, remaining, line_no + 1, lines, bytes, max_bytes)

      :eof ->
        finish(lines, offset, false)

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp collect(device, buffer, offset, remaining, line_no, lines, bytes, max_bytes) do
    case next_line(device, buffer, max_bytes - bytes) do
      :eof ->
        finish(lines, offset, false)

      {:error, reason} ->
        Result.error(reason)

      {:ok, line, _rest, :budget} ->
        # The line was cut at the byte budget before its newline, so content
        # provably remains beyond the window.
        finish([assemble(line, :budget) | lines], offset, true)

      {:ok, line, rest, termination} ->
        line = assemble(line, termination)

        if bytes + byte_size(line) > max_bytes do
          available = max(max_bytes - bytes, 0)
          finish([utf8_prefix(line, available) | lines], offset, true)
        else
          collect(
            device,
            rest,
            offset,
            remaining - 1,
            line_no + 1,
            [line | lines],
            bytes + byte_size(line),
            max_bytes
          )
        end
    end
  end

  defp assemble(line, :newline), do: line <> "\n"
  defp assemble(line, :final), do: line

  # A line cut at the byte budget may end mid codepoint; back it off to a
  # valid boundary so the returned content stays decodable.
  defp assemble(line, :budget), do: utf8_prefix(line, byte_size(line))

  # Reads one line in fixed-size chunks. `budget` caps how many bytes an
  # unterminated line may occupy, so oversized lines are cut before they can
  # grow the buffer. Termination is :newline, :final (last line at EOF), or
  # :budget (cut early; more bytes follow).
  defp next_line(device, buffer, budget) do
    case split_newline(buffer) do
      {line, rest} ->
        {:ok, line, rest, :newline}

      :none when byte_size(buffer) > budget ->
        {:ok, binary_part(buffer, 0, budget), "", :budget}

      :none ->
        refill(device, buffer, budget)
    end
  end

  defp refill(device, acc, budget) do
    case IO.read(device, @chunk_bytes) do
      :eof ->
        if acc == "", do: :eof, else: {:ok, acc, "", :final}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        with :ok <- text_chunk(chunk) do
          classify_line(device, acc <> chunk, budget)
        end
    end
  end

  defp classify_line(device, buffer, budget) do
    case split_newline(buffer) do
      {line, rest} ->
        {:ok, line, rest, :newline}

      :none when byte_size(buffer) > budget ->
        {:ok, binary_part(buffer, 0, budget), "", :budget}

      :none ->
        refill(device, buffer, budget)
    end
  end

  defp skip_line(device, buffer) do
    case split_newline(buffer) do
      {_line, rest} ->
        {:ok, rest}

      :none ->
        skip_chunk(device)
    end
  end

  defp skip_chunk(device) do
    case IO.read(device, @chunk_bytes) do
      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}

      chunk ->
        with :ok <- text_chunk(chunk), do: skip_line(device, chunk)
    end
  end

  defp split_newline(buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> {line, rest}
      [_whole] -> :none
    end
  end

  defp text_chunk(chunk) do
    if String.contains?(chunk, <<0>>), do: {:error, :binary_file}, else: :ok
  end

  defp more_content?(device, buffer) do
    buffer != "" or IO.read(device, 1) != :eof
  end

  defp utf8_prefix(_line, 0), do: ""

  defp utf8_prefix(line, size) do
    prefix = binary_part(line, 0, size)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(line, size - 1)
  end

  defp finish(lines, offset, more?) do
    content = lines |> Enum.reverse() |> IO.iodata_to_binary()

    Result.ok(content,
      truncated: more?,
      metadata: %{
        "offset" => offset,
        "lines" => length(lines),
        "bytes" => byte_size(content)
      }
    )
  end

  defp limits(policy) do
    %{
      max_bytes: RuntimeConfig.policy(policy, :tool_read_max_bytes, @defaults[:max_bytes]),
      max_lines: RuntimeConfig.policy(policy, :tool_read_max_lines, @defaults[:max_lines])
    }
  end
end
