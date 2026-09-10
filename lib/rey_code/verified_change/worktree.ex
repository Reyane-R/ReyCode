defmodule ReyCode.VerifiedChange.Worktree do
  @moduledoc """
  Git edit isolation and bounded, base-bound binary patches. Not an OS sandbox.

  A fresh index ignores caller index flags. Ignored files and empty directories
  are outside this Git snapshot. Attributes and submodules are rejected rather
  than claiming a faithful patch for transformations or nested repositories.
  Temporary indexes are owned here; retained worktrees are owned by the caller.
  """

  alias ReyCode.Hashing
  alias ReyCode.Provider.Command
  alias ReyCode.Security.{CanonicalPath, Environment}

  @max_patch_bytes 2 * 1024 * 1024
  @max_files_count 10_000
  @max_snapshot_bytes 128 * 1024 * 1024

  @spec source(String.t(), integer()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def source(workspace, deadline_ms) do
    with {:ok, source} <- CanonicalPath.resolve(workspace),
         {:ok, root} <- git(source, ["rev-parse", "--show-toplevel"], deadline_ms),
         {:ok, root} <- CanonicalPath.resolve(String.trim(root)),
         true <- root == source,
         {:ok, commit} <- git(source, ["rev-parse", "--verify", "HEAD"], deadline_ms),
         commit = String.trim(commit),
         :ok <- unchanged(source, commit, deadline_ms) do
      {:ok, source, commit}
    else
      false -> {:error, :workspace_not_git_root}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create(ReyCode.Orchestration.VerifiedChange.t(), integer()) ::
          {:ok, binary()} | {:error, term()}
  def create(record, deadline_ms) do
    git(
      record.source_workspace,
      ["worktree", "add", "--detach", record.workspace, record.base_commit],
      deadline_ms
    )
  end

  @spec unchanged(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def unchanged(workspace, base_commit, deadline_ms) do
    with {:ok, head} <- git(workspace, ["rev-parse", "HEAD"], deadline_ms),
         {:ok, status} <-
           git(workspace, ["status", "--porcelain=v1", "--untracked-files=all"], deadline_ms),
         {:ok, patch, _hash} <- snapshot(workspace, base_commit, deadline_ms) do
      if String.trim(head) == base_commit and status == "" and patch == "",
        do: :ok,
        else: {:error, :source_not_same_clean_base}
    end
  end

  @doc "Captures at most 10000 Git files / 128 MiB of file bytes into a patch capped at 2 MiB."
  @spec snapshot(String.t(), String.t(), integer()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def snapshot(workspace, base_commit, deadline_ms) do
    index =
      Path.join(
        System.tmp_dir!(),
        "reycode-index-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    try do
      with {:ok, head} <- git(workspace, ["rev-parse", "HEAD"], deadline_ms),
           :ok <- same_head(head, base_commit),
           {:ok, _} <- git(workspace, ["read-tree", base_commit], deadline_ms, index),
           {:ok, files} <- git(workspace, ["ls-files", "--stage", "-z"], deadline_ms, index),
           :ok <- supported(files),
           :ok <- snapshot_files(workspace, index, deadline_ms),
           {:ok, _} <- git(workspace, ["add", "-A", "--", "."], deadline_ms, index),
           {:ok, files} <- git(workspace, ["ls-files", "--stage", "-z"], deadline_ms, index),
           :ok <- supported(files),
           {:ok, patch} <-
             git(
               workspace,
               [
                 "diff",
                 "--cached",
                 "--binary",
                 "--full-index",
                 "--no-color",
                 "--src-prefix=a/",
                 "--dst-prefix=b/",
                 "--unified=3",
                 "--no-ext-diff",
                 "--no-textconv",
                 "--no-renames",
                 base_commit,
                 "--"
               ],
               deadline_ms,
               index
             ),
           true <- String.valid?(patch) do
        {:ok, patch, Hashing.sha256_hex(base_commit <> "\n" <> patch)}
      else
        false -> {:error, :non_utf8_patch}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(index)
      File.rm(index <> ".lock")
    end
  end

  defp same_head(head, base_commit) do
    if String.trim(head) == base_commit, do: :ok, else: {:error, :head_changed}
  end

  defp snapshot_files(workspace, index, deadline_ms) do
    with {:ok, attributes} <-
           git(workspace, ["rev-parse", "--git-path", "info/attributes"], deadline_ms),
         false <- File.exists?(Path.expand(String.trim(attributes), workspace)),
         {:ok, files} <-
           git(
             workspace,
             ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
             deadline_ms,
             index
           ) do
      paths = String.split(files, <<0>>, trim: true) |> Enum.uniq()

      if length(paths) <= @max_files_count,
        do: inspect_paths(workspace, paths),
        else: {:error, :snapshot_file_count_exceeded}
    else
      true -> {:error, :unsupported_git_attributes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_paths(workspace, paths) do
    Enum.reduce_while(paths, {:ok, 0}, fn path, {:ok, bytes} ->
      case inspect_path(workspace, path, bytes) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _bytes} -> :ok
      error -> error
    end
  end

  defp inspect_path(workspace, path, bytes) do
    ancestors = Path.split(Path.dirname(path))
    directories = Enum.scan(ancestors, workspace, &Path.join(&2, &1))

    attributes? =
      Enum.any?([workspace | directories], &File.exists?(Path.join(&1, ".gitattributes")))

    if attributes? do
      {:error, :unsupported_git_attributes}
    else
      case File.lstat(Path.join(workspace, path)) do
        {:ok, %{type: type, size: size}}
        when type in [:regular, :symlink] and bytes + size <= @max_snapshot_bytes ->
          {:ok, bytes + size}

        {:error, :enoent} ->
          {:ok, bytes}

        _ ->
          {:error, :unsupported_or_oversized_snapshot_file}
      end
    end
  end

  defp supported(files) do
    unsupported? =
      files
      |> String.split(<<0>>, trim: true)
      |> Enum.any?(fn entry ->
        String.starts_with?(entry, "160000 ") or String.ends_with?(entry, "/.gitattributes") or
          String.ends_with?(entry, "\t.gitattributes")
      end)

    if unsupported?, do: {:error, :unsupported_git_snapshot}, else: :ok
  end

  defp git(workspace, args, deadline_ms, index \\ nil) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    env =
      Environment.allowlisted()
      |> Map.merge(%{
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0"
      })

    env = if index, do: Map.put(env, "GIT_INDEX_FILE", index), else: env
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
