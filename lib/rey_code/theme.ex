defmodule ReyCode.Theme do
  @moduledoc false

  @unicode_activity_frames {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
  @ascii_activity_frames {"|", "/", "-", "\\"}

  def default do
    Breeze.Theme.new(
      name: "reycode",
      dark: true,
      defaults: %{
        text: "#E8E5DC",
        background: "#090908",
        border: "#3A3833"
      },
      palette: %{
        muted: "#79766F",
        primary: "#F4F1E8",
        secondary: "#C8C4B9",
        warning: "#F2A93B",
        error: "#FF3B30",
        success: "#E8E5DC",
        accent: "#FF3B30",
        surface: "#11110F",
        panel: "#1A1916"
      },
      extras: %{cursor: "#FF3B30"}
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
