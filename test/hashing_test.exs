defmodule ReyCode.HashingTest do
  use ExUnit.Case, async: true

  alias ReyCode.Hashing

  @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "sha256/1 returns the raw digest" do
    assert Hashing.sha256("abc") == Base.decode16!(@abc_sha256, case: :lower)
  end

  test "sha256_hex/1 returns lowercase hexadecimal" do
    assert Hashing.sha256_hex("abc") == @abc_sha256
  end

  test "file_sha256_hex/1 hashes file contents with the same algorithm" do
    path = Path.join(System.tmp_dir!(), "rey_code_hashing_#{System.unique_integer([:positive])}")
    File.write!(path, "abc")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, @abc_sha256} = Hashing.file_sha256_hex(path)
  end

  test "file_sha256_hex/1 reports missing files without raising" do
    assert {:error, :enoent} = Hashing.file_sha256_hex("/nonexistent/rey_code_hashing")
  end

  test "file_sha256_hex/1 reports unreadable inputs without raising" do
    directory = Path.join(System.tmp_dir!(), "rey_code_hashing_dir_#{System.unique_integer()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    assert {:error, :eisdir} = Hashing.file_sha256_hex(directory)
  end
end
