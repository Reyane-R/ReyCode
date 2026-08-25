defmodule ReyCode.TUI.Spinner do
  @moduledoc false

  @frames ["|", "/", "-", "\\"]
  @frame_ms 120

  @doc "Current frame glyph for the running-turn spinner."
  def glyph, do: Enum.at(@frames, frame())

  defp frame,
    do:
      rem(div(System.monotonic_time(:millisecond), @frame_ms * length(@frames)), length(@frames))
end
