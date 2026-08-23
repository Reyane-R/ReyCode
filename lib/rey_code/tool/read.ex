defmodule ReyCode.Tool.Read do
  @moduledoc """
  Reads a bounded, line-oriented slice of a UTF-8 text file within the
  trusted roots.

  `offset` (1-based line number) and `limit` bound every read, so large files
  are consumed in windows instead of failing wholesale. The result reports the
  returned range in its metadata and sets `truncated` when more content lies
  beyond the window. Binary files are rejected instead of garbled.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result, Support}

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
          collect(device, offset, limit, 1, [], 0, max_bytes)
        after
          File.close(device)
        end

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp collect(device, offset, remaining, line_no, lines, bytes, max_bytes) do
    if remaining <= 0 or bytes >= max_bytes do
      finish(lines, offset, IO.read(device, :line) != :eof)
    else
      read_next(device, offset, remaining, line_no, lines, bytes, max_bytes)
    end
  end

  defp read_next(device, offset, remaining, line_no, lines, bytes, max_bytes) do
    case IO.read(device, :line) do
      :eof -> finish(lines, offset, false)
      {:error, reason} -> Result.error(reason)
      line -> consume(line, device, offset, remaining, line_no, lines, bytes, max_bytes)
    end
  end

  defp consume(line, device, offset, remaining, line_no, lines, bytes, max_bytes) do
    cond do
      String.contains?(line, <<0>>) ->
        Result.error(:binary_file)

      line_no < offset ->
        collect(device, offset, remaining, line_no + 1, lines, bytes, max_bytes)

      true ->
        collect(
          device,
          offset,
          remaining - 1,
          line_no + 1,
          [line | lines],
          bytes + byte_size(line),
          max_bytes
        )
    end
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
