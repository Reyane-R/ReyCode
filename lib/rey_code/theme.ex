defmodule ReyCode.Theme do
  @moduledoc false

  @unicode_activity_frames {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
  @ascii_activity_frames {"|", "/", "-", "\\"}

  def default do
    Breeze.Theme.new(
      name: "reycode",
      dark: true,
      defaults: %{
        text: "#E4F0FF",
        background: "#040609",
        border: "#78313F"
      },
      palette: %{
        muted: "#8999AD",
        primary: "#25E0FF",
        secondary: "#FF7185",
        warning: "#FFD166",
        error: "#FF5268",
        success: "#68E8AD",
        accent: "#FF2D3D",
        surface: "#09121C",
        panel: "#121321"
      },
      extras: %{cursor: "#25E0FF"}
    )
  end

  @doc "Returns one frame without allocating or indexing a list."
  @spec activity_frame(:unicode | :ascii, non_neg_integer()) :: String.t()
  def activity_frame(:unicode, index),
    do: elem(@unicode_activity_frames, Integer.mod(index, tuple_size(@unicode_activity_frames)))

  def activity_frame(:ascii, index),
    do: elem(@ascii_activity_frames, Integer.mod(index, tuple_size(@ascii_activity_frames)))

  @doc "Static active glyph used when reduced motion is enabled."
  @spec activity_static_glyph(:unicode | :ascii) :: String.t()
  def activity_static_glyph(:unicode), do: "•"
  def activity_static_glyph(:ascii), do: "*"

  @doc "Stable terminal glyph for every durable Turn Outcome."
  @spec activity_outcome_glyph(atom() | nil) :: String.t()
  def activity_outcome_glyph(:completed), do: "✓"
  def activity_outcome_glyph(:partial), do: "◐"
  def activity_outcome_glyph(:reworked), do: "↻"
  def activity_outcome_glyph(:failed), do: "×"
  def activity_outcome_glyph(:cancelled), do: "■"
  def activity_outcome_glyph(_outcome), do: "·"

  @doc "Stable idle indicator."
  @spec activity_idle_glyph() :: String.t()
  def activity_idle_glyph, do: "•"
end
