defmodule ReyCode.Theme do
  @moduledoc false

  @unicode_activity_frames {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
  @ascii_activity_frames {"|", "/", "-", "\\"}

  # Chrome recedes, content speaks: structural lines sit just above the
  # background, cyan marks focus and interaction only, and bright red is
  # reserved for state (errors, cancellation, the breach sweep).
  def default do
    Breeze.Theme.new(
      name: "reycode",
      dark: true,
      defaults: %{
        text: "#E8E2E3",
        background: "#090508",
        border: "#3B1119"
      },
      palette: %{
        muted: "#7D6E75",
        primary: "#25E0FF",
        secondary: "#D96B7C",
        warning: "#FCEE09",
        identity: "#FCEE09",
        boundary: "#5A1A24",
        error: "#FF5268",
        success: "#68E8AD",
        accent: "#FF2D3D",
        surface: "#0E0709",
        panel: "#1C0D16"
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
