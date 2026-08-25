defmodule ReyCode.TUI.Mentions do
  @moduledoc """
  Expands `@path` and `#path` file-attachment tokens inside a draft.

  A token is a leading `@` or `#` followed by a path-like run of non-space
  characters. Markdown (`## heading`) and bare `#`/`@` are left untouched.
  Only files inside the workspace can be attached; each file is bounded by
  `max_bytes` and the total expansion by `max_total_bytes`.
  """

  alias ReyCode.Security.Workspace

  @max_total_bytes 2_000_000

  @type reason ::
          :file_not_found
          | :outside_workspace
          | :file_too_large
          | :unreadable
          | :total_too_large

  @doc """
  Expands every attachment token in `body`.

  Returns `{:ok, expanded_body, [attached_path]}` or
  `{:error, {token, reason}}` on the first failing token.
  """
  @spec expand(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), [String.t()]} | {:error, {String.t(), reason()}}
  def expand(body, workspace, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, 512_000)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)

    body
    |> unique_tokens()
    |> Enum.reduce_while({:ok, body, 0, []}, fn token, {:ok, acc, attached_bytes, paths} ->
      case attach(token, workspace, max_bytes, max_total, acc, attached_bytes) do
        {:ok, updated, new_bytes, path} ->
          {:cont, {:ok, updated, new_bytes, [path | paths]}}

        {:error, reason} ->
          {:halt, {:error, {token, reason}}}
      end
    end)
    |> case do
      {:ok, expanded, _bytes, paths} -> {:ok, expanded, Enum.reverse(paths)}
      {:error, {token, reason}} -> {:error, {token, reason}}
    end
  end

  defp unique_tokens(body) do
    ~r/([#@][^\s#@]+)/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  defp attach(token, workspace, max_bytes, max_total, body, attached_bytes) do
    path = Path.expand(String.slice(token, 1..-1//1), workspace)

    with {:ok, _canonical} <- Workspace.contained?(path, roots: [workspace]),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         :ok <- check_size(size, max_bytes, :file_too_large),
         :ok <- check_size(size + attached_bytes, max_total, :total_too_large),
         {:ok, content} <- File.read(path) do
      expanded = body <> "\n\n" <> path <> ":\n```\n" <> content <> "\n```\n"
      {:ok, expanded, size + attached_bytes, path}
    else
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, :workspace_outside_policy} -> {:error, :outside_workspace}
      {:error, :file_too_large} -> {:error, :file_too_large}
      {:error, :total_too_large} -> {:error, :total_too_large}
      {:ok, %File.Stat{}} -> {:error, :unreadable}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp check_size(size, limit, reason) do
    if size <= limit, do: :ok, else: {:error, reason}
  end
end
