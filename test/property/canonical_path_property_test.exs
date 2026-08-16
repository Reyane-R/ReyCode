defmodule ReyCode.Property.CanonicalPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.Security.CanonicalPath

  property "resolve is idempotent on real directories" do
    check all(
            segments <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                min_length: 1,
                max_length: 5
              )
          ) do
      root = create_nested_dir(segments)

      assert {:ok, resolved} = CanonicalPath.resolve(root)
      assert {:ok, resolved_again} = CanonicalPath.resolve(resolved)
      assert resolved == resolved_again
    end
  end

  property "resolve strips trailing dot segments on real directories" do
    check all(
            segments <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                min_length: 1,
                max_length: 5
              )
          ) do
      root = create_nested_dir(segments)
      dotted = root <> "/."

      assert {:ok, from_dotted} = CanonicalPath.resolve(dotted)
      assert {:ok, from_clean} = CanonicalPath.resolve(root)
      assert from_dotted == from_clean
    end
  end

  property "resolve rejects paths containing NUL bytes" do
    check all(prefix <- string(:alphanumeric, min_length: 1, max_length: 5)) do
      assert {:error, :invalid_path} = CanonicalPath.resolve("/" <> prefix <> <<0>>)
    end
  end

  defp create_nested_dir(segments) do
    path = System.tmp_dir!()

    Enum.reduce(segments, path, fn segment, acc ->
      dir = Path.join(acc, segment)
      File.mkdir_p!(dir)
      dir
    end)
  end
end
