defmodule ReyCode.Security.CanonicalPath do
  @moduledoc false

  @max_symlinks 40

  @spec resolve(term()) :: {:ok, String.t()} | {:error, term()}
  def resolve(path) when is_binary(path) do
    if path == "" or String.contains?(path, <<0>>) do
      {:error, :invalid_path}
    else
      path
      |> Path.expand()
      |> Path.split()
      |> drop_root()
      |> resolve_segments([], 0)
    end
  rescue
    ArgumentError -> {:error, :invalid_path}
  end

  def resolve(_path), do: {:error, :invalid_path}

  @doc "Resolves a path's real identity, allowing a missing final file component."
  @spec resolve_identity(term()) :: {:ok, String.t()} | {:error, term()}
  def resolve_identity(path) when is_binary(path) do
    path = Path.expand(path)

    case resolve(path) do
      {:ok, _canonical_path} = result -> result
      {:error, :enoent} = error -> resolve_missing_leaf(path, error)
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_path}
  end

  def resolve_identity(_path), do: {:error, :invalid_path}

  defp resolve_missing_leaf(path, error) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with {:ok, canonical_parent} <- resolve(Path.dirname(path)) do
          {:ok, Path.join(canonical_parent, Path.basename(path))}
        end

      {:ok, _stat} ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_segments([], resolved, _links), do: {:ok, join_absolute(resolved)}

  defp resolve_segments(["." | rest], resolved, links),
    do: resolve_segments(rest, resolved, links)

  defp resolve_segments([".." | rest], resolved, links),
    do: resolve_segments(rest, Enum.drop(resolved, -1), links)

  defp resolve_segments([segment | rest], resolved, links) do
    candidate = join_absolute(resolved ++ [segment])

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} when links < @max_symlinks ->
        resolve_link(candidate, rest, resolved, links + 1)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :too_many_symlinks}

      {:ok, _stat} ->
        resolve_segments(rest, resolved ++ [segment], links)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_link(candidate, rest, resolved, links) do
    with {:ok, target} <- File.read_link(candidate) do
      target_segments = target |> Path.split() |> drop_root()

      if Path.type(target) == :absolute do
        resolve_segments(target_segments ++ rest, [], links)
      else
        resolve_segments(target_segments ++ rest, resolved, links)
      end
    end
  end

  defp drop_root(["/" | segments]), do: segments
  defp drop_root(segments), do: segments

  defp join_absolute([]), do: "/"
  defp join_absolute(segments), do: Path.join(["/" | segments])
end
