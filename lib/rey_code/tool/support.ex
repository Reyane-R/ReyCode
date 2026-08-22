defmodule ReyCode.Tool.Support do
  @moduledoc false

  alias ReyCode.Security.Workspace
  alias ReyCode.Tool.Request

  @doc "Reads a string argument, returning `default` when missing, non-binary, or keyed by atom/string."
  @spec arg(map(), atom() | String.t(), term()) :: term()
  def arg(arguments, key, default \\ nil) when is_map(arguments) do
    string_key = to_string(key)

    with :error <- Map.fetch(arguments, string_key),
         :error <- Map.fetch(arguments, key) do
      default
    else
      {:ok, value} when is_binary(value) -> value
      {:ok, _other} -> default
    end
  end

  @doc "Returns `{:ok, canonical}` when `key` is present and resolves within the trusted roots."
  @spec require_path(map(), atom(), Request.t()) :: {:ok, String.t()} | {:error, :missing_path}
  def require_path(arguments, key, %Request{} = request) do
    case arg(arguments, key) do
      nil -> {:error, :missing_path}
      path -> within_roots(path, request)
    end
  end

  @doc "Returns `:ok` when `value` is a non-empty binary, otherwise `{:error, reason}`."
  @spec require_present(term(), atom()) :: :ok | {:error, atom()}
  def require_present(value, _reason) when value not in [nil, ""], do: :ok
  def require_present(_value, reason), do: {:error, reason}

  @doc """
  Resolves `path` within the request's trusted roots.

  Relative paths are joined to the invocation workspace before containment is
  checked, so tool arguments can never reach files through the process
  working directory. Returns `{:ok, canonical}` or `{:error, reason}`.
  """
  @spec within_roots(term(), Request.t()) :: {:ok, String.t()} | {:error, term()}
  def within_roots(path, %Request{} = request) when is_binary(path) do
    resolved =
      if Path.type(path) == :relative,
        do: Path.join(request.workspace, path),
        else: path

    Workspace.contained?(resolved, roots: Request.roots(request))
  end

  def within_roots(_path, _request), do: {:error, :invalid_path}
end
