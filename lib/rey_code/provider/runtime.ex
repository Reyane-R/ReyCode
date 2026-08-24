defmodule ReyCode.Provider.Runtime do
  @moduledoc "A discovered provider runtime used for a specific invocation."

  alias ReyCode.Hashing
  alias ReyCode.RuntimeConfig.{OpenAICompatible, OpenCode, Simulator, Workspace}
  alias ReyCode.Security.CanonicalPath

  @type status :: :available | :checking | :configured | :error | :missing | :unchecked

  @enforce_keys [:module, :status]
  @type executable_identity :: %{
          path: String.t(),
          device: {non_neg_integer(), non_neg_integer()},
          inode: non_neg_integer(),
          sha256: String.t()
        }

  defstruct [
    :module,
    :provider_id,
    :executable,
    :executable_identity,
    :version,
    :config,
    :workspace_policy,
    models: [],
    status: :unchecked
  ]

  @type t :: %__MODULE__{
          module: module(),
          provider_id: atom() | nil,
          executable: binary() | nil,
          executable_identity: executable_identity() | nil,
          version: binary() | nil,
          config: OpenCode.t() | OpenAICompatible.t() | Simulator.t() | nil,
          workspace_policy: Workspace.t() | nil,
          models: [binary()],
          status: status()
        }

  @spec identify_executable(term()) :: {:ok, executable_identity()} | {:error, term()}
  def identify_executable(path) do
    with {:ok, canonical} <- CanonicalPath.resolve(path),
         {:ok, before_stat} <- File.stat(canonical),
         :ok <- regular_file(before_stat),
         {:ok, contents} <- File.read(canonical),
         {:ok, after_stat} <- File.stat(canonical),
         true <- stable_file?(before_stat, after_stat) do
      {:ok,
       %{
         path: canonical,
         device: {after_stat.major_device, after_stat.minor_device},
         inode: after_stat.inode,
         sha256: Hashing.sha256_hex(contents)
       }}
    else
      false -> {:error, :executable_changed_during_fingerprint}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec revalidate_executable(t()) ::
          {:ok, t()}
          | {:error, {:executable_unavailable, term()}}
          | {:error, {:executable_changed, map()}}
  def revalidate_executable(%__MODULE__{executable: path, executable_identity: nil} = runtime) do
    case identify_executable(path) do
      {:ok, identity} ->
        {:ok, %{runtime | executable: identity.path, executable_identity: identity}}

      {:error, reason} ->
        {:error, {:executable_unavailable, reason}}
    end
  end

  def revalidate_executable(
        %__MODULE__{executable: path, executable_identity: expected} = runtime
      ) do
    case identify_executable(path) do
      {:ok, ^expected} ->
        {:ok, %{runtime | executable: expected.path}}

      {:ok, actual} ->
        {:error, {:executable_changed, %{expected: expected, actual: actual}}}

      {:error, reason} ->
        {:error, {:executable_changed, %{expected: expected, actual: %{error: reason}}}}
    end
  end

  defp regular_file(%File.Stat{type: :regular}), do: :ok
  defp regular_file(_stat), do: {:error, :not_regular_file}

  defp stable_file?(left, right) do
    {left.major_device, left.minor_device, left.inode, left.size, left.mtime, left.ctime} ==
      {right.major_device, right.minor_device, right.inode, right.size, right.mtime, right.ctime}
  end
end
