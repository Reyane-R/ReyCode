defmodule ReyCode.Security.Workspace do
  @moduledoc "Canonical workspace validation and local-root policy."

  alias ReyCode.Security.CanonicalPath

  @type reason ::
          :invalid_workspace
          | :workspace_not_found
          | :workspace_not_directory
          | :workspace_root_forbidden
          | :workspace_outside_policy

  @spec validate(term(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def validate(path, opts \\ []) do
    with {:ok, canonical} <- canonical_workspace(path),
         :ok <- reject_filesystem_root(canonical),
         :ok <- ensure_directory(canonical),
         true <- allowed?(canonical, policy_roots(opts)) do
      {:ok, canonical}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :workspace_outside_policy}
    end
  end

  defp canonical_workspace(path) do
    case CanonicalPath.resolve(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, :enoent} -> {:error, :workspace_not_found}
      {:error, :enotdir} -> {:error, :workspace_not_directory}
      {:error, _reason} -> {:error, :invalid_workspace}
    end
  end

  defp reject_filesystem_root("/"), do: {:error, :workspace_root_forbidden}
  defp reject_filesystem_root(_canonical), do: :ok

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :workspace_not_directory}
      {:error, :enoent} -> {:error, :workspace_not_found}
      {:error, _reason} -> {:error, :invalid_workspace}
    end
  end

  defp policy_roots(opts) do
    roots =
      Keyword.get_lazy(opts, :roots, fn ->
        Application.get_env(:rey_code, :workspace_roots, default_roots())
      end)

    roots
    |> List.wrap()
    |> Enum.flat_map(fn root ->
      case CanonicalPath.resolve(root) do
        {:ok, "/"} -> []
        {:ok, canonical} -> [canonical]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
  end

  defp default_roots, do: [File.cwd!(), System.tmp_dir!()]

  defp allowed?(path, roots) do
    Enum.any?(roots, fn root -> path == root or String.starts_with?(path, root <> "/") end)
  end
end
