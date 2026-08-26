defmodule ReyCode.TUI.Spinner do
  @moduledoc "Shared theme-owned frame adapter for active-work presentation."

  alias ReyCode.Theme

  @doc "Returns the shared frame glyph for a clock index and motion preference."
  @spec glyph(non_neg_integer(), boolean(), :unicode | :ascii) :: String.t()
  def glyph(frame_index, reduced_motion?, style \\ :unicode)

  def glyph(_frame_index, true, style), do: Theme.activity_static_glyph(style)
  def glyph(frame_index, false, style), do: Theme.activity_frame(style, frame_index)

  @doc "Chooses the safe frame style for the attached terminal."
  @spec style(String.t() | nil) :: :unicode | :ascii
  def style(term \\ System.get_env("TERM"))
  def style("dumb"), do: :ascii
  def style(_term), do: :unicode
end
