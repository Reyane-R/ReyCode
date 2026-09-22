defmodule ReyCode.TUI.InputBurstTest do
  use ExUnit.Case, async: true

  # A fast wheel delivers several SGR mouse reports in one terminal read. They
  # must decode as mouse events; falling through to raw text would insert
  # "[<65;26;29M" into the composer.
  test "a burst of SGR mouse reports decodes as separate mouse events, never text" do
    burst = "\e[<65;26;29M\e[<65;26;29M\e[<64;26;29M"

    decoded = Breeze.Input.decode_all(burst)

    assert length(decoded) == 3

    assert Enum.map(decoded, fn {:mouse, %{"button" => button}} -> button end) ==
             ["wheel_down", "wheel_down", "wheel_up"]
  end

  test "single reports and plain keys decode unchanged" do
    assert [{:mouse, %{"button" => "wheel_down"}}] = Breeze.Input.decode_all("\e[<65;1;1M")
    assert [{:key, "Enter"}] = Breeze.Input.decode_all("\r")
    assert [{:key, %{"key" => "ab"}}] = Breeze.Input.decode_all("ab")
  end
end
