defmodule ReyCode.Tool.Support do
  @moduledoc false

  alias ReyCode.Security.Workspace
  alias ReyCode.Tool.Request

  @doc """
  Reads a required string argument.

  A missing key and a wrongly typed value are distinct failures: neither is
  coerced, so a numeric or map `content` can never silently become an empty
  string that truncates a file.
  """
  @spec require_arg(map(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, {:missing_argument | :invalid_argument, atom()}}
  def require_arg(arguments, key) when is_map(arguments) do
    case fetch_argument(arguments, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_argument, key}}
      :error -> {:error, {:missing_argument, key}}
    end
  end

  @doc """
  Reads an optional string argument, substituting `default` only when the key
  is absent. A present but non-binary value is an error, never a coercion.
  """
  @spec arg(map(), atom() | String.t(), term()) ::
          {:ok, term()} | {:error, {:invalid_argument, atom()}}
  def arg(arguments, key, default \\ nil) when is_map(arguments) do
    case fetch_argument(arguments, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_argument, key}}
      :error -> {:ok, default}
    end
  end

  defp fetch_argument(arguments, key) do
    string_key = to_string(key)

    with :error <- Map.fetch(arguments, string_key),
         :error <- Map.fetch(arguments, key) do
      :error
    else
      {:ok, value} -> {:ok, value}
    end
  end

  @doc """
  Reads a non-negative integer argument, accepting integers or digit strings
  and falling back to `default` when absent.
  """
  @spec integer_arg(map(), atom() | String.t(), integer()) ::
          {:ok, integer()} | {:error, :invalid_integer}
  def integer_arg(arguments, key, default) when is_map(arguments) do
    with :error <- Map.fetch(arguments, to_string(key)),
         :error <- Map.fetch(arguments, key) do
      {:ok, default}
    else
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/^\d+$/, String.trim(value)),
          do: {:ok, String.to_integer(String.trim(value))},
          else: {:error, :invalid_integer}

      {:ok, _other} ->
        {:error, :invalid_integer}
    end
  end

  @doc "Returns `{:ok, canonical}` when `key` is present and resolves within the trusted roots."
  @spec require_path(map(), atom(), Request.t()) ::
          {:ok, String.t()} | {:error, :missing_path | {:invalid_argument, atom()} | term()}
  def require_path(arguments, key, %Request{} = request) do
    case require_arg(arguments, key) do
      {:ok, path} -> within_roots(path, request)
      {:error, {:missing_argument, _key}} -> {:error, :missing_path}
      {:error, _reason} = error -> error
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
