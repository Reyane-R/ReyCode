defmodule ReyCode.ArtifactStore do
  @moduledoc "Bounded private spool for large durable ToolRun outputs."

  alias ReyCode.Hashing
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.Tool.Result

  @id_pattern ~r/\A[0-9a-f]{32}\z/
  @max_scan_count 4_096

  @type policy :: ReyCode.RuntimeConfig.Artifacts.t()

  @doc "Spools a large successful result and replaces inline output with a bounded reference preview."
  @spec spool(Result.t(), policy(), String.t(), String.t()) :: Result.t()
  def spool(%Result{ok: true, output: output} = result, policy, invocation_id, run_id)
      when is_binary(output) do
    if byte_size(output) > policy.spool_threshold_bytes do
      do_spool(result, output, policy, invocation_id, run_id)
    else
      result
    end
  end

  def spool(result, _policy, _invocation_id, _run_id), do: result

  @doc "Reads one bounded artifact byte window by opaque ID."
  @spec read(policy(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), map()} | {:error, atom() | tuple()}
  def read(policy, artifact_id, offset, limit)
      when is_binary(artifact_id) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit > 0 do
    with true <- Regex.match?(@id_pattern, artifact_id) || {:error, :invalid_artifact_id},
         true <- limit <= policy.preview_bytes || {:error, :artifact_window_too_large},
         {:ok, path} <- artifact_path(policy.root, artifact_id),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular || {:error, :artifact_not_found},
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        {:ok, bytes} = :file.pread(file, offset, min(limit, max(stat.size - offset, 0)))

        {:ok, bytes,
         %{
           "artifact_id" => artifact_id,
           "offset" => offset,
           "bytes" => byte_size(bytes),
           "total_bytes" => stat.size
         }}
      after
        File.close(file)
      end
    else
      false -> {:error, :invalid_artifact}
      {:error, :enoent} -> {:error, :artifact_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(_policy, _artifact_id, _offset, _limit), do: {:error, :invalid_artifact_window}

  @doc "Lists newest artifact metadata without reading contents."
  @spec list(policy()) :: [map()]
  def list(policy) do
    policy.root
    |> artifact_files()
    |> Enum.take(policy.max_artifact_count)
    |> Enum.map(fn %{id: id, stat: stat} ->
      %{id: id, bytes: stat.size, modified_at: stat.mtime}
    end)
  end

  defp do_spool(result, output, policy, invocation_id, run_id) do
    stored = TextBuffer.truncate_utf8(output, policy.max_artifact_bytes)
    complete? = byte_size(stored) == byte_size(output) and not result.truncated
    artifact_id = stored |> Hashing.sha256_hex() |> String.slice(0, 32)

    case persist(policy.root, artifact_id, stored) do
      :ok ->
        preview = TextBuffer.truncate_utf8(stored, policy.preview_bytes)

        metadata =
          Map.merge(result.metadata, %{
            "artifact_id" => artifact_id,
            "artifact_bytes" => byte_size(stored),
            "artifact_complete" => complete?,
            "invocation_id" => invocation_id,
            "tool_run_id" => run_id
          })

        reference =
          "artifact://#{artifact_id} · #{byte_size(stored)} bytes · " <>
            if(complete?, do: "complete", else: "captured prefix")

        _ = prune(policy)
        Result.ok(reference <> "\n\n" <> preview, truncated: true, metadata: metadata)

      {:error, _reason} ->
        result
    end
  end

  defp persist(root, artifact_id, bytes) do
    with :ok <- File.mkdir_p(root),
         {:ok, path} <- artifact_path(root, artifact_id) do
      temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        with :ok <- File.write(temporary, bytes, [:binary]),
             :ok <- File.chmod(temporary, 0o600) do
          File.rename(temporary, path)
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp prune(policy) do
    files = artifact_files(policy.root)

    files
    |> Enum.drop(policy.max_artifact_count)
    |> Enum.each(&File.rm(&1.path))

    :ok
  end

  defp artifact_files(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.take(@max_scan_count)
        |> Enum.flat_map(&artifact_file(root, &1))
        |> Enum.sort_by(& &1.stat.mtime, :desc)

      {:error, _reason} ->
        []
    end
  end

  defp artifact_file(root, name) do
    with [id] <- Regex.run(~r/\A([0-9a-f]{32})\.txt\z/, name, capture: :all_but_first),
         path = Path.join(root, name),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular do
      [%{id: id, path: path, stat: stat}]
    else
      _other -> []
    end
  end

  defp artifact_path(root, artifact_id) do
    path = Path.expand(Path.join(root, artifact_id <> ".txt"))
    root = Path.expand(root)

    if Path.dirname(path) == root, do: {:ok, path}, else: {:error, :invalid_artifact_id}
  end
end
