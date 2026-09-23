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

  test "typed text ahead of a sequence and a cursor key beside a report both decode" do
    assert [{:key, %{"key" => "ab"}}, {:mouse, _}, {:key, "ArrowUp"}] =
             Breeze.Input.decode_all("ab\e[<65;1;1M\e[A")
  end

  test "single reports and plain keys decode unchanged" do
    assert [{:mouse, %{"button" => "wheel_down"}}] = Breeze.Input.decode_all("\e[<65;1;1M")
    assert [{:key, "Enter"}] = Breeze.Input.decode_all("\r")
    assert [{:key, %{"key" => "ab"}}] = Breeze.Input.decode_all("ab")
    assert [{:key, "Escape"}] = Breeze.Input.decode_all("\e")
  end

  # A report split across two reads must never surface its first half as a
  # bare Escape: that key cancels the active turn.
  test "an incomplete trailing escape sequence is held back for the next read" do
    assert Breeze.Input.split_complete("\e[<65;43;34M\e[<65") == {"\e[<65;43;34M", "\e[<65"}

    assert Breeze.Input.split_complete("\e[<65;43;34M\e[<64;44;") ==
             {"\e[<65;43;34M", "\e[<64;44;"}

    assert Breeze.Input.split_complete("abc\e") == {"abc", "\e"}
    assert Breeze.Input.split_complete("\e[") == {"", "\e["}
    assert Breeze.Input.split_complete("\eO") == {"", "\eO"}
    assert Breeze.Input.split_complete("\e[<65;43;34M") == {"\e[<65;43;34M", ""}
    assert Breeze.Input.split_complete("\e[A") == {"\e[A", ""}
    assert Breeze.Input.split_complete("\eOP") == {"\eOP", ""}
    assert Breeze.Input.split_complete("\ea") == {"\ea", ""}
    assert Breeze.Input.split_complete("plain") == {"plain", ""}

    {head, partial} = Breeze.Input.split_complete("\e[<65;43;34M\e[<64;44;")
    assert [{:mouse, _}] = Breeze.Input.decode_all(head)
    assert [{:mouse, %{"button" => "wheel_up"}}] = Breeze.Input.decode_all(partial <> "33M")
  end
end
