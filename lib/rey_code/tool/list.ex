defmodule ReyCode.Tool.List do
  @moduledoc "Lists the entries of a directory within the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    case Support.require_path(arguments, :path, request) do
      {:ok, canonical} -> list_entries(canonical)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp list_entries(canonical) do
    case File.ls(canonical) do
      {:ok, entries} -> Result.ok(Enum.join(entries, "\n"))
      {:error, reason} -> Result.error(reason)
    end
  end
end
