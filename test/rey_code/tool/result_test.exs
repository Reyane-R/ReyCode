defmodule ReyCode.Tool.ResultTest do
  use ExUnit.Case, async: true

  alias ReyCode.Tool.Result

  # A model that omits `source_hash` makes the Edit adapter return a tuple
  # error. The wire form must stay JSON so the durable append never raises.
  test "tuple and atom errors encode as text on the wire" do
    wire = Result.to_wire(Result.error({:missing_argument, :source_hash}))

    assert wire["error"] == "missing_argument: source_hash"
    assert {:ok, _json} = Jason.encode(wire)

    assert Result.to_wire(Result.error(:missing_path))["error"] == "missing_path"
    assert Result.to_wire(Result.error("plain text"))["error"] == "plain text"
    assert Result.to_wire(Result.error(%{"code" => 1}))["error"] == %{"code" => 1}
    assert Result.to_wire(Result.error({:nested, %{a: {1, 2}}}))["error"] =~ "nested"
  end
end
