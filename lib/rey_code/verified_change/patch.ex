defmodule ReyCode.VerifiedChange.Patch do
  @moduledoc """
  Applies only retained bytes, never a regenerated candidate-worktree diff.

  The caller must durably journal intent and hold the Engine source barrier before
  calling. The 60-second operation uses bounded Git children and a private patch
  outside both workspaces. External writers are not sandboxed: revalidation
  narrows races but cannot provide a filesystem transaction. Any uncertainty after
  mutation requires explicit reconciliation, never an automatic retry.

  Reconciliation compares the entire bounded Git snapshot, including untracked
  files, with the exact retained patch at the original HEAD, and requires the
  real index to remain at base. Ignored files and empty directories are outside
  the Git snapshot contract. Temporary-index Git object writes do not alter the
  source files or real index. Discard performs no filesystem cleanup.
  """

  alias ReyCode.Hashing
  alias ReyCode.Orchestration.VerifiedChange
  alias ReyCode.Provider.Command
  alias ReyCode.Security.{CanonicalPath, Environment}
  alias ReyCode.VerifiedChange.Worktree

  @timeout_ms 60_000
  @max_patch_bytes 2 * 1024 * 1024

  @type result :: {:applied | :discarded, nil} | {:failed | :indeterminate, String.t()}

  @spec execute(VerifiedChange.t(), :apply | :discard, pid()) :: result()
  def execute(change, decision, owner \\ self())
  def execute(_change, :discard, _owner), do: {:discarded, nil}

  def execute(change, :apply, owner) do
    deadline_ms = System.monotonic_time(:millisecond) + @timeout_ms

    with :ok <- validate(change),
         :ok <- source_identity(change, deadline_ms),
         :ok <- Worktree.unchanged(change.source_workspace, change.base_commit, deadline_ms) do
      with_patch(change, deadline_ms, owner)
    else
      {:error, _reason} -> {:failed, "retained_patch_or_clean_base_validation_failed"}
    end
  end

  @spec reconcile(VerifiedChange.t(), :apply | :discard) :: result()
  def reconcile(_change, :discard), do: {:discarded, nil}

  def reconcile(change, :apply) do
    reconcile_snapshot(change, System.monotonic_time(:millisecond) + @timeout_ms)
  end

  defp reconcile_snapshot(change, deadline_ms) do
    with :ok <- validate(change),
         :ok <- source_identity(change, deadline_ms),
         {:ok, _} <-
           git(
             change.source_workspace,
             ["diff", "--cached", "--quiet", change.base_commit, "--"],
             deadline_ms
           ),
         {:ok, patch, hash} <-
           Worktree.snapshot(change.source_workspace, change.base_commit, deadline_ms) do
      cond do
        patch == change.patch and hash == change.patch_hash -> {:applied, nil}
        patch == "" -> {:failed, "source_at_pristine_base"}
        true -> {:indeterminate, "source_does_not_match_retained_patch_or_base"}
      end
    else
      {:error, _reason} -> {:indeterminate, "source_snapshot_unavailable_or_changed"}
    end
  end

  defp validate(change) do
    if change.phase == "ready" and is_binary(change.patch) and
         byte_size(change.patch) <= @max_patch_bytes and
         change.patch_hash == Hashing.sha256_hex(change.base_commit <> "\n" <> change.patch),
       do: :ok,
       else: {:error, :invalid_retained_patch}
  end

  defp source_identity(change, deadline_ms) do
    with {:ok, source} <- CanonicalPath.resolve(change.source_workspace),
         true <- source == change.source_workspace,
         {:ok, root} <- git(source, ["rev-parse", "--show-toplevel"], deadline_ms),
         {:ok, root} <- CanonicalPath.resolve(String.trim(root)),
         true <- root == source do
      :ok
    else
      _ -> {:error, :source_identity_changed}
    end
  end

  defp with_patch(change, deadline_ms, owner) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "reycode-retained-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    with {:ok, temporary_root} <- CanonicalPath.resolve(System.tmp_dir!()),
         false <-
           contained?(temporary_root, change.source_workspace) or
             contained?(temporary_root, change.workspace),
         :ok <- File.mkdir(directory) do
      try do
        patch_file = Path.join(directory, "retained.patch")

        with :ok <- File.chmod(directory, 0o700),
             :ok <- File.write(patch_file, change.patch, [:binary, :exclusive]),
             :ok <- File.chmod(patch_file, 0o400),
             {:ok, frozen} <- File.read(patch_file),
             true <- frozen == change.patch do
          apply_frozen(change, patch_file, deadline_ms, owner)
        else
          _ -> {:failed, "temporary_patch_failed"}
        end
      after
        File.rm(Path.join(directory, "retained.patch"))
        File.rmdir(directory)
      end
    else
      _ -> {:failed, "temporary_patch_directory_failed"}
    end
  end

  defp apply_frozen(%{patch: ""} = change, _patch_file, deadline_ms, _owner),
    do: reconcile_snapshot(change, deadline_ms)

  defp apply_frozen(change, patch_file, deadline_ms, owner) do
    source = change.source_workspace

    with {:ok, _} <-
           git(source, ["apply", "--check", "--whitespace=nowarn", "--", patch_file], deadline_ms),
         :ok <- source_identity(change, deadline_ms),
         :ok <- Worktree.unchanged(source, change.base_commit, deadline_ms),
         true <- Process.alive?(owner) do
      case git(source, ["apply", "--whitespace=nowarn", "--", patch_file], deadline_ms) do
        {:ok, _} ->
          confirm_applied(change, deadline_ms)

        {:error, _} ->
          {:indeterminate, "patch_execution_uncertain"}
      end
    else
      false -> {:failed, "engine_stopped_before_apply"}
      {:error, _} -> {:failed, "patch_check_or_clean_base_validation_failed"}
    end
  end

  defp confirm_applied(change, deadline_ms) do
    case reconcile_snapshot(change, deadline_ms) do
      {:applied, nil} = result -> result
      _ -> {:indeterminate, "post_apply_snapshot_mismatch"}
    end
  end

  defp contained?(path, root),
    do: path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  defp git(workspace, args, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    env =
      Environment.allowlisted()
      |> Map.merge(%{
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_OPTIONAL_LOCKS" => "0"
      })

    assignments = Enum.map(env, fn {key, value} -> key <> "=" <> value end)

    if remaining_ms > 0 do
      Command.run(
        "/usr/bin/env",
        ["-i" | assignments] ++
          [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "core.autocrlf=false",
            "-c",
            "core.filemode=true",
            "-c",
            "core.ignoreStat=false",
            "-c",
            "core.sparseCheckout=false",
            "-c",
            "core.fsmonitor=false" | args
          ],
        cd: workspace,
        timeout_ms: min(remaining_ms, 10_000),
        max_output_bytes: @max_patch_bytes
      )
    else
      {:error, :timeout}
    end
  end
end
