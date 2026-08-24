defmodule ReyCode.Tool.List do
  @moduledoc """
  Lists the entries of a directory within the trusted roots.

  Traversal stops after `:tool_list_max_entries + 1` entries or
  `:tool_list_timeout_ms`, so the limit bounds both returned output and
  directory enumeration work.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig.Tools.List, as: ListPolicy
  alias ReyCode.Tool.{DirectoryEntries, Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    %ListPolicy{} = policy = Keyword.fetch!(opts, :policy)
    max_entries = policy.max_entries
    timeout_ms = policy.timeout_ms

    case Support.require_path(arguments, :path, request) do
      {:ok, canonical} -> list_entries(canonical, max_entries, timeout_ms)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp list_entries(canonical, max_entries, timeout_ms) do
    case DirectoryEntries.take(canonical, max_entries, timeout_ms) do
      {:ok, entries, truncated?} ->
        Result.ok(Enum.join(entries, "\n"),
          truncated: truncated?,
          metadata: %{"entries" => length(entries)}
        )

      {:error, reason} ->
        Result.error(reason)
    end
  end
end
