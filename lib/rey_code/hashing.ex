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

  @doc "Returns a lowercase hexadecimal SHA-256 digest for a file's contents."
  @spec file_sha256_hex(Path.t()) :: String.t()
  def file_sha256_hex(path) do
    digest =
      path
      |> File.stream!(64 * 1024, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    Base.encode16(digest, case: :lower)
  end
end
