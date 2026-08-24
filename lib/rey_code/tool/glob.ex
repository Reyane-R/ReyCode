defmodule ReyCode.Tool.Glob do
  @moduledoc """
  Expands a glob pattern rooted within the trusted roots.

  Patterns may not escape the root (`..`, absolute, or home-relative forms
  are rejected), and every expanded result is re-validated against the trust
  boundary after symlink resolution, so links pointing outside the workspace
  never appear in results.

  Traversal is bounded: collection halts at the result budget, directory
  visits are capped, and each directory contributes at most the budget's
  worth of candidate entries. The platform readdir API returns a whole
  directory per call, so one enormous directory still costs that single
  listing; nothing beyond it is accumulated.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.RuntimeConfig
  alias ReyCode.Security.Workspace
  alias ReyCode.Tool.{Request, Result, Support}

  @default_max_results 10_000

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    max_results =
      RuntimeConfig.policy(
        Keyword.fetch!(opts, :policy),
        :tool_glob_max_results,
        @default_max_results
      )

    with {:ok, canonical} <- Support.require_path(arguments, :path, request),
         {:ok, pattern} <- Support.require_arg(arguments, :pattern),
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
    state = collect_matches([{canonical, Path.split(pattern)}], request, max_results + 1)
    paths = state.paths |> Enum.reverse() |> Enum.sort()
    {paths, overflow} = Enum.split(paths, max_results)
    respond(paths, overflow != [] or state.halted, max_results)
  end

  defp collect_matches(_pending, _request, limit, %{count: count} = state)
       when count >= limit,
       do: %{state | halted: true}

  defp collect_matches(
         _pending,
         _request,
         _limit,
         %{visited: visited, visit_limit: limit} = state
       )
       when visited >= limit,
       do: %{state | halted: true}

  defp collect_matches([], _request, _limit, state), do: state

  defp collect_matches([{path, []} | pending], request, limit, state) do
    state = %{state | visited: state.visited + 1}
    state = add_match(path, request, state)
    collect_matches(pending, request, limit, state)
  end

  defp collect_matches([{path, ["**" | rest]} | pending], request, limit, state) do
    state = %{state | visited: state.visited + 1}
    children = children(path, state.visit_limit - state.visited)

    recursive =
      Enum.flat_map(children, fn child ->
        cond do
          directory?(child) -> [{child, ["**" | rest]}]
          rest == [] -> [{child, []}]
          true -> []
        end
      end)

    collect_matches([{path, rest} | recursive] ++ pending, request, limit, state)
  end

  defp collect_matches([{path, [component | rest]} | pending], request, limit, state) do
    state = %{state | visited: state.visited + 1}

    matches =
      path
      |> Path.join(component)
      |> Path.wildcard()
      |> reject_hidden_matches(component)
      |> Enum.take(state.visit_limit - state.visited)
      |> Enum.filter(&traversable?(&1, rest))
      |> Enum.map(&{&1, rest})

    collect_matches(matches ++ pending, request, limit, state)
  end

  defp collect_matches(pending, request, limit) do
    state = %{
      paths: [],
      seen: %{},
      count: 0,
      visited: 0,
      visit_limit: max(limit * 10, 100),
      halted: false
    }

    collect_matches(pending, request, limit, state)
  end

  defp add_match(path, request, state) do
    if Map.has_key?(state.seen, path) or not contained?(path, request) do
      state
    else
      %{
        state
        | paths: [path | state.paths],
          seen: Map.put(state.seen, path, true),
          count: state.count + 1
      }
    end
  end

  defp children(path, limit) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.take(limit)
        |> Enum.map(&Path.join(path, &1))

      {:error, _reason} ->
        []
    end
  end

  defp hidden_name?(path), do: path |> Path.basename() |> String.starts_with?(".")

  defp reject_hidden_matches(paths, "." <> _explicit_hidden), do: paths
  defp reject_hidden_matches(paths, _component), do: Enum.reject(paths, &hidden_name?/1)

  defp traversable?(_path, []), do: true
  defp traversable?(path, _rest), do: directory?(path)

  defp directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  defp contained?(path, request) do
    match?({:ok, _canonical}, Workspace.contained?(path, roots: Request.roots(request)))
  end

  defp respond(paths, false, _max_results) do
    Result.ok(Enum.join(paths, "\n"), metadata: %{"matches" => length(paths)})
  end

  defp respond(paths, true, max_results) do
    Result.ok(Enum.join(paths, "\n"),
      truncated: true,
      metadata: %{"matches" => min(length(paths), max_results)}
    )
  end
end
