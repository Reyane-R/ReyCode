defmodule ReyCode.Orchestration.DelegationWorktree do
  @moduledoc "Bounded git-worktree isolation and patch application for delegated Invocations."

  alias ReyCode.Hashing
  alias ReyCode.Provider.Command
  alias ReyCode.Security.CanonicalPath

  @timeout_ms 10_000
  @max_output_bytes 2_000_000

  @type isolation :: %{workspace: String.t(), source_workspace: String.t()}

  @doc "Creates one detached temporary worktree for a delegated Invocation."
  @spec create(String.t(), String.t()) :: {:ok, isolation()} | {:error, term()}
  def create(source_workspace, child_invocation_id) do
    with git when is_binary(git) <- System.find_executable("git"),
         {:ok, source} <- canonical_git_root(git, source_workspace) do
      path = worktree_path(source, child_invocation_id)
      File.mkdir_p!(Path.dirname(path))

      case Command.run(git, ["worktree", "add", "--detach", path, "HEAD"],
             cd: source,
             timeout_ms: @timeout_ms,
             max_output_bytes: @max_output_bytes
           ) do
        {:ok, _output} -> {:ok, %{workspace: path, source_workspace: source}}
        {:error, reason} -> {:error, {:worktree_creation_failed, reason}}
      end
    else
      nil -> {:error, :git_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Checks and applies one isolated worktree patch to its source workspace."
  @spec apply(isolation()) :: :ok | {:error, term()}
  def apply(%{workspace: workspace, source_workspace: source}) do
    git = System.find_executable("git")
    patch = Path.join(workspace, ".reycode-delegation.patch")

    try do
      with true <- is_binary(git),
           {:ok, _output} <- command(git, ["add", "-N", "--", "."], workspace),
           {:ok, diff} <-
             command(git, ["diff", "--binary", "--no-ext-diff", "HEAD"], workspace),
           :ok <- write_patch(patch, diff),
           :ok <- apply_patch(git, source, patch, diff) do
        cleanup(%{workspace: workspace, source_workspace: source})
      else
        false -> {:error, :git_not_found}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(patch)
    end
  end

  @doc "Removes an isolated worktree without applying its changes."
  @spec cleanup(isolation()) :: :ok | {:error, term()}
  def cleanup(%{workspace: workspace, source_workspace: source}) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        case Command.run(git, ["worktree", "remove", "--force", workspace],
               cd: source,
               timeout_ms: @timeout_ms,
               max_output_bytes: @max_output_bytes
             ) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:worktree_cleanup_failed, reason}}
        end
    end
  end

  defp canonical_git_root(git, workspace) do
    with {:ok, output} <- command(git, ["rev-parse", "--show-toplevel"], workspace),
         {:ok, root} <- CanonicalPath.resolve(String.trim(output)),
         {:ok, expected} <- CanonicalPath.resolve(workspace) do
      if root == expected, do: {:ok, root}, else: {:error, :workspace_not_git_root}
    else
      {:error, _reason} -> {:error, :workspace_not_git_repository}
    end
  end

  defp worktree_path(source, child_invocation_id) do
    source_hash = source |> Hashing.sha256_hex() |> String.slice(0, 16)
    Path.join([System.tmp_dir!(), "reycode-worktrees", source_hash, child_invocation_id])
  end

  defp write_patch(_path, ""), do: :ok
  defp write_patch(path, diff), do: File.write(path, diff, [:binary])

  defp apply_patch(_git, _source, _patch, ""), do: :ok

  defp apply_patch(git, source, patch, _diff) do
    with {:ok, _output} <- command(git, ["apply", "--check", patch], source),
         {:ok, _output} <- command(git, ["apply", patch], source) do
      :ok
    else
      {:error, reason} -> {:error, {:worktree_apply_failed, reason}}
    end
  end

  defp command(git, args, workspace) do
    Command.run(git, args,
      cd: workspace,
      timeout_ms: @timeout_ms,
      max_output_bytes: @max_output_bytes
    )
  end
end
