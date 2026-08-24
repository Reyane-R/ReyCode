defmodule ReyCode.Tool.Glob do
  @moduledoc """
  Expands a glob pattern rooted within the trusted roots.

  Patterns may not escape the root (`..`, absolute, or home-relative forms
  are rejected), and every expanded result is re-validated against the trust
  boundary after symlink resolution, so links pointing outside the workspace
  never appear in results.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Security.Workspace
  alias ReyCode.Tool.{Request, Result, Support}

  @default_max_results 10_000

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    pattern = Support.arg(arguments, :pattern)

    max_results =
      RuntimeConfig.policy(
        Keyword.fetch!(opts, :policy),
        :tool_glob_max_results,
        @default_max_results
      )

    with {:ok, canonical} <- Support.require_path(arguments, :path, request),
         :ok <- Support.require_present(pattern, :missing_pattern),
         :ok <- require_contained_pattern(pattern) do
      expand(canonical, pattern, request, max_results)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp require_contained_pattern(pattern) do
    escapes? =
      Path.type(pattern) == :absolute or
        pattern |> Path.split() |> Enum.any?(&(&1 in ["..", "~"]))

    if escapes?, do: {:error, :invalid_pattern}, else: :ok
  end

  defp expand(canonical, pattern, request, max_results) do
    canonical
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.filter(&contained?(&1, request))
    |> split_at_cap(max_results)
    |> respond(max_results)
  end

  defp contained?(path, request) do
    match?({:ok, _canonical}, Workspace.contained?(path, roots: Request.roots(request)))
  end

  defp split_at_cap(paths, max_results), do: Enum.split(paths, max_results)

  defp respond({paths, []}, _max_results) do
    Result.ok(Enum.join(paths, "\n"), metadata: %{"matches" => length(paths)})
  end

  defp respond({paths, _overflow}, max_results) do
    Result.ok(Enum.join(paths, "\n"),
      truncated: true,
      metadata: %{"matches" => max_results}
    )
  end
end
