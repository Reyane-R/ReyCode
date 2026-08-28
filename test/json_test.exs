defmodule ReyCode.JSONTest do
  use ExUnit.Case, async: true

  alias ReyCode.JSON

  test "normalize/1 converts nested atom keys to durable JSON keys" do
    value = %{session_id: "room-1", nested: [%{ready: true}], count: 2}

    assert JSON.normalize(value) == %{
             "session_id" => "room-1",
             "nested" => [%{"ready" => true}],
             "count" => 2
           }
  end
end
