defmodule ReyCode.Tool.List do
  @moduledoc """
  Lists the entries of a directory within the trusted roots.

  Traversal stops after `:tool_list_max_entries + 1` entries or
  `:tool_list_timeout_ms`, so the limit bounds both returned output and
  directory enumeration work.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Tool.{DirectoryEntries, Request, Result, Support}

  @default_max_entries 2_000
  @default_timeout_ms 10_000

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    policy = Keyword.fetch!(opts, :policy)
    max_entries = RuntimeConfig.policy(policy, :tool_list_max_entries, @default_max_entries)
    timeout_ms = RuntimeConfig.policy(policy, :tool_list_timeout_ms, @default_timeout_ms)

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
