defmodule ReyCode.Tool.Read do
  @moduledoc "Reads a UTF-8 text file within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @max_bytes Application.compile_env(:rey_code, :tool_read_max_bytes, 512_000)

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    case Support.require_path(arguments, :path, request) do
      {:ok, canonical} -> read_bounded(canonical)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp read_bounded(canonical) do
    case File.read(canonical) do
      {:ok, content} when byte_size(content) > @max_bytes ->
        Result.error(:file_too_large)

      {:ok, content} ->
        Result.ok(content)

      {:error, reason} ->
        Result.error(reason)
    end
  end
end
