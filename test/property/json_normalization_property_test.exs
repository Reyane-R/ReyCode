defmodule ReyCode.Property.JsonNormalizationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ReyCode.JSON

  property "normalization is idempotent" do
    check all(value <- json_term()) do
      once = JSON.normalize(value)
      twice = JSON.normalize(once)
      assert once == twice
    end
  end

  property "normalization never raises on JSON-encodable values" do
    check all(value <- json_term()) do
      assert is_binary(Jason.encode!(value))
      assert json_succeeded?(value)
    end
  end

  defp json_succeeded?(value) do
    _ = JSON.normalize(value)
    true
  rescue
    _ -> false
  end

  # Generates values that Jason can encode.
  defp json_term do
    one_of([
      string(:alphanumeric, max_length: 50),
      integer(-1_000_000..1_000_000),
      float(min: -1_000.0, max: 1_000.0),
      boolean(),
      constant(nil),
      list_of(string(:alphanumeric, max_length: 10), max_length: 5),
      map_of(string(:alphanumeric, max_length: 10), string(:alphanumeric, max_length: 10),
        max_length: 5
      )
    ])
  end
end
