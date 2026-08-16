defmodule ReyCode.Hashing do
  @moduledoc "Shared SHA-256 hashing helpers."

  @doc "Returns the raw SHA-256 digest for binary data."
  @spec sha256(binary()) :: binary()
  def sha256(data) when is_binary(data), do: :crypto.hash(:sha256, data)

  @doc "Returns a lowercase hexadecimal SHA-256 digest for binary data."
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(data) when is_binary(data) do
    data
    |> sha256()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Streams a file through SHA-256 and returns its lowercase hex digest.

  Open and read failures are returned as tagged errors instead of raising.
  """
  @spec file_sha256_hex(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def file_sha256_hex(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case hash_device(device, :crypto.hash_init(:sha256)) do
            {:ok, digest} -> {:ok, Base.encode16(digest, case: :lower)}
            {:error, reason} -> {:error, reason}
          end
        after
          :ok = File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_device(device, state) do
    case IO.binread(device, 64 * 1024) do
      data when is_binary(data) and byte_size(data) > 0 ->
        hash_device(device, :crypto.hash_update(state, data))

      :eof ->
        {:ok, :crypto.hash_final(state)}

      {:error, reason} ->
        {:error, {:read_failure, reason}}
    end
  end
end
