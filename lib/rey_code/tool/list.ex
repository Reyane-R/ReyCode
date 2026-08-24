defmodule ReyCode.Tool.List do
  @moduledoc """
  Lists the entries of a directory within the trusted roots.

  Output is bounded by `:tool_list_max_entries` and flagged `truncated`
  beyond it. The platform readdir API returns a whole directory in one call,
  so listing a directory with millions of entries still costs that one
  listing; the bound caps everything downstream of it.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{Request, Result, Support}

  @default_max_entries 2_000

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    max_entries =
      RuntimeConfig.policy(
        Keyword.fetch!(opts, :policy),
        :tool_list_max_entries,
        @default_max_entries
      )

    case Support.require_path(arguments, :path, request) do
      {:ok, canonical} -> list_entries(canonical, max_entries)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp list_entries(canonical, max_entries) do
    case File.ls(canonical) do
      {:ok, entries} ->
        {shown, overflow} = Enum.split(entries, max_entries)

        Result.ok(Enum.join(shown, "\n"),
          truncated: overflow != [],
          metadata: %{"entries" => length(shown)}
        )

      {:error, reason} ->
        Result.error(reason)
    end
  end
end
