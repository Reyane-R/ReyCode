defmodule ReyCode.Tool.Edit do
  @moduledoc """
  Applies one bounded batch of unique replacements against a hashed file snapshot.

  Every request names the SHA-256 returned by `read`. All patches are validated
  against that exact source, checked for overlap, applied in memory, and committed
  with one same-directory rename. A stale snapshot or ambiguous patch performs no
  mutation.
  """

  @behaviour ReyCode.Tool

  import Bitwise, only: [band: 2]

  alias ReyCode.Hashing
  alias ReyCode.RuntimeConfig.Tools.Edit, as: EditPolicy
  alias ReyCode.Tool.{Request, Result, Support}

  @hash_pattern ~r/\A[0-9a-f]{64}\z/

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    %EditPolicy{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, path} <- Support.require_arg(arguments, :path),
         {:ok, source_hash} <- Support.require_arg(arguments, :source_hash),
         {:ok, raw_patches} <- require_value(arguments, :patches),
         :ok <- Support.require_present(path, :missing_path),
         {:ok, source_hash} <- validate_hash(source_hash),
         {:ok, patches} <- validate_patches(raw_patches, policy),
         {:ok, canonical} <- Support.within_roots(path, request) do
      apply_batch(canonical, source_hash, patches, policy.max_bytes)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp validate_hash(source_hash) when is_binary(source_hash) do
    if Regex.match?(@hash_pattern, source_hash),
      do: {:ok, source_hash},
      else: {:error, :invalid_source_hash}
  end

  defp validate_patches(patches, policy)
       when is_list(patches) and patches != [] and length(patches) <= policy.max_patches do
    with {:ok, normalized} <- normalize_patches(patches),
         :ok <- unique_anchors(normalized),
         :ok <- patch_size(normalized, policy.max_bytes) do
      {:ok, normalized}
    end
  end

  defp validate_patches(patches, _policy) when is_list(patches) do
    if patches == [],
      do: {:error, :patches_required},
      else: {:error, :too_many_patches}
  end

  defp validate_patches(_patches, _policy), do: {:error, {:invalid_argument, :patches}}

  defp normalize_patches(patches) do
    Enum.reduce_while(patches, {:ok, []}, fn patch, {:ok, normalized} ->
      case normalize_patch(patch) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_patch(patch) when is_map(patch) do
    old = argument(patch, :old_string)
    new = argument(patch, :new_string)

    cond do
      not is_binary(old) or old == "" -> {:error, {:invalid_argument, :old_string}}
      not is_binary(new) -> {:error, {:invalid_argument, :new_string}}
      not String.valid?(old) or not String.valid?(new) -> {:error, :binary_patch}
      true -> {:ok, %{old: old, new: new}}
    end
  end

  defp normalize_patch(_patch), do: {:error, {:invalid_argument, :patch}}

  defp require_value(arguments, key) do
    case Map.fetch(arguments, Atom.to_string(key)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(arguments, key)
    end
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_argument, key}}
    end
  end

  defp argument(arguments, key),
    do: Map.get(arguments, key, Map.get(arguments, Atom.to_string(key)))

  defp unique_anchors(patches) do
    if Enum.uniq_by(patches, & &1.old) == patches,
      do: :ok,
      else: {:error, :duplicate_patch_anchor}
  end

  defp patch_size(patches, max_bytes) do
    bytes = Enum.reduce(patches, 0, &(&2 + byte_size(&1.old) + byte_size(&1.new)))
    if bytes <= max_bytes, do: :ok, else: {:error, :content_too_large}
  end

  defp apply_batch(canonical, source_hash, patches, max_bytes) do
    with {:ok, stat} <- File.stat(canonical),
         :ok <- source_size(stat.size, max_bytes),
         {:ok, content} <- File.read(canonical),
         :ok <- text_content(content),
         :ok <- snapshot_matches(content, source_hash),
         {:ok, replacements} <- locate_replacements(content, patches),
         :ok <- non_overlapping(replacements),
         updated <- apply_replacements(content, replacements),
         :ok <- commit(canonical, source_hash, updated, stat) do
      result_hash = Hashing.sha256_hex(updated)

      Result.ok("edited #{canonical}",
        metadata: %{
          "path" => canonical,
          "patches" => length(patches),
          "source_hash" => source_hash,
          "result_hash" => result_hash,
          "bytes" => byte_size(updated)
        }
      )
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp source_size(source_bytes, max_bytes) do
    if source_bytes <= max_bytes, do: :ok, else: {:error, :file_too_large}
  end

  defp text_content(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: :ok,
      else: {:error, :binary_file}
  end

  defp snapshot_matches(content, source_hash) do
    if Hashing.sha256_hex(content) == source_hash,
      do: :ok,
      else: {:error, :stale_source_hash}
  end

  defp locate_replacements(content, patches) do
    Enum.reduce_while(patches, {:ok, []}, fn patch, {:ok, replacements} ->
      case :binary.matches(content, patch.old) do
        [{position, length}] ->
          replacement = %{position: position, length: length, new: patch.new}
          {:cont, {:ok, [replacement | replacements]}}

        [] ->
          {:halt, {:error, :old_string_not_found}}

        _matches ->
          {:halt, {:error, :ambiguous_match}}
      end
    end)
  end

  defp non_overlapping(replacements) do
    replacements
    |> Enum.sort_by(& &1.position)
    |> Enum.reduce_while(0, fn replacement, previous_end ->
      if replacement.position < previous_end,
        do: {:halt, {:error, :overlapping_patches}},
        else: {:cont, replacement.position + replacement.length}
    end)
    |> case do
      {:error, _reason} = error -> error
      _end_position -> :ok
    end
  end

  defp apply_replacements(content, replacements) do
    replacements
    |> Enum.sort_by(& &1.position, :desc)
    |> Enum.reduce(content, fn replacement, updated ->
      prefix = binary_part(updated, 0, replacement.position)
      suffix_start = replacement.position + replacement.length
      suffix = binary_part(updated, suffix_start, byte_size(updated) - suffix_start)
      prefix <> replacement.new <> suffix
    end)
  end

  defp commit(canonical, source_hash, updated, stat) do
    temporary =
      canonical <>
        ".reycode-edit-" <>
        Integer.to_string(System.unique_integer([:positive, :monotonic]))

    try do
      with :ok <- write_exclusive(temporary, updated),
           :ok <- File.chmod(temporary, band(stat.mode, 0o7777)),
           {:ok, current_hash} <- Hashing.file_sha256_hex(canonical),
           :ok <- current_snapshot(current_hash, source_hash) do
        File.rename(temporary, canonical)
      end
    after
      File.rm(temporary)
    end
  end

  defp write_exclusive(path, content) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        try do
          IO.binwrite(device, content)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_snapshot(source_hash, source_hash), do: :ok
  defp current_snapshot(_current_hash, _source_hash), do: {:error, :stale_source_hash}
end
