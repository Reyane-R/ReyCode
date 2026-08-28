defmodule ReyCode.Orchestration.DelegationWorktree do
  @moduledoc "Bounded git-worktree isolation and patch application for delegated Invocations."

  alias ReyCode.Hashing
  alias ReyCode.Provider.{Command, TextBuffer}
  alias ReyCode.Security.CanonicalPath

  @timeout_ms 10_000
  @max_output_bytes 2_000_000
  @max_preview_bytes 65_536

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

  @doc "Returns one bounded human-readable patch preview without applying it."
  @spec preview(isolation()) :: {:ok, String.t()} | {:error, term()}
  def preview(%{"workspace" => workspace, "source_workspace" => source}),
    do: preview(%{workspace: workspace, source_workspace: source})

  def preview(%{workspace: workspace}) do
    with git when is_binary(git) <- System.find_executable("git"),
         {:ok, _output} <- command(git, ["add", "-N", "--", "."], workspace),
         {:ok, stat} <- command(git, ["diff", "--stat", "HEAD"], workspace),
         {:ok, diff} <-
           command(git, ["diff", "--no-ext-diff", "--unified=3", "HEAD"], workspace) do
      preview =
        [String.trim_trailing(stat), String.trim_trailing(diff)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      if byte_size(preview) > @max_preview_bytes,
        do:
          {:ok, TextBuffer.truncate_utf8(preview, @max_preview_bytes) <> "\n… preview truncated"},
        else: {:ok, preview}
    else
      nil -> {:error, :git_not_found}
      {:error, reason} -> {:error, {:worktree_preview_failed, reason}}
    end
  end

  @doc "Checks and applies one isolated patch while retaining the worktree for durable resolution."
  @spec apply_keep(isolation()) :: :ok | {:error, term()}
  def apply_keep(%{"workspace" => workspace, "source_workspace" => source}),
    do: apply_keep(%{workspace: workspace, source_workspace: source})

  def apply_keep(%{workspace: workspace, source_workspace: source}) do
    git = System.find_executable("git")
    patch = Path.join(workspace, ".reycode-delegation.patch")

    try do
      with true <- is_binary(git),
           {:ok, _output} <- command(git, ["add", "-N", "--", "."], workspace),
           {:ok, diff} <-
             command(git, ["diff", "--binary", "--no-ext-diff", "HEAD"], workspace),
           :ok <- write_patch(patch, diff),
           :ok <- apply_patch_idempotent(git, source, patch, diff) do
        :ok
      else
        false -> {:error, :git_not_found}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(patch)
    end
  end

  @doc "Applies one isolated worktree patch and removes the worktree."
  @spec apply(isolation()) :: :ok | {:error, term()}
  def apply(isolation) do
    with :ok <- apply_keep(isolation), do: cleanup(isolation)
  end

  @doc "Removes an isolated worktree without applying its changes."
  @spec cleanup(isolation()) :: :ok | {:error, term()}
  def cleanup(%{"workspace" => workspace, "source_workspace" => source}),
    do: cleanup(%{workspace: workspace, source_workspace: source})

  def cleanup(%{workspace: workspace, source_workspace: source}) do
    if File.exists?(workspace), do: remove_worktree(workspace, source), else: :ok
  end

  defp remove_worktree(workspace, source) do
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

  defp apply_patch_idempotent(_git, _source, _patch, ""), do: :ok

  defp apply_patch_idempotent(git, source, patch, _diff) do
    case command(git, ["apply", "--check", patch], source) do
      {:ok, _output} ->
        case command(git, ["apply", patch], source) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:worktree_apply_failed, reason}}
        end

      {:error, reason} ->
        case command(git, ["apply", "--reverse", "--check", patch], source) do
          {:ok, _already_applied} -> :ok
          {:error, _not_applied} -> {:error, {:worktree_apply_failed, reason}}
        end
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
