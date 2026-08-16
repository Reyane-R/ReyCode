defmodule ReyCode.Property.HashingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Hashing

  property "sha256_hex is deterministic — identical input yields identical output" do
    check all(data <- string(:printable, max_length: 1_000)) do
      assert Hashing.sha256_hex(data) == Hashing.sha256_hex(data)
    end
  end

  property "sha256_hex output is always 64 lowercase hex characters" do
    check all(data <- string(:printable, max_length: 1_000)) do
      hex = Hashing.sha256_hex(data)

      assert byte_size(hex) == 64
      assert hex == String.downcase(hex)
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hex)
    end
  end

  property "sha256_hex distinguishes different inputs" do
    check all(
            a <- string(:alphanumeric, min_length: 1, max_length: 50),
            b <- string(:alphanumeric, min_length: 1, max_length: 50)
          ) do
      if a != b do
        refute Hashing.sha256_hex(a) == Hashing.sha256_hex(b)
      end
    end
  end

  property "sha256 raw digest is always 32 bytes" do
    check all(data <- string(:printable, max_length: 1_000)) do
      digest = Hashing.sha256(data)
      assert byte_size(digest) == 32
    end
  end
end
