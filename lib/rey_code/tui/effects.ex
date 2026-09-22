defmodule ReyCode.TUI.Effects do
  @moduledoc """
  Cell-bounded, renderer-local HUD animation. Breeze owns the decoration timer
  and removes it with the element. No animation changes layout, focus, input,
  or durable state; only the decorative element's existing cells are replaced.
  """

  @behaviour Breeze.Implicit

  alias ReyCode.TUI.Blackwall

  @frame_ms 100
  @entrance_ms 700
  @max_width_count 160
  @glyphs {"/", "#", ":", "+", "=", "_"}
  @emblem {
    "    ╱────────────╲     ",
    "   ╱  ╱──────╲    ╲    ",
    "  ╱  ╱   ◆    ╲    ╲   ",
    " ◇───┤ REYCODE ├────◇  ",
    "  ╲  ╲   ◆    ╱    ╱   ",
    "   ╲  ╲──────╱    ╱    ",
    "    ╲────────────╱     "
  }

  defstruct kind: :scanner,
            started_ms: 0,
            enabled?: false,
            skip?: false,
            ascii?: false,
            width_count: 24,
            rows_count: 1,
            clip: {0, 0, 0, 0},
            text: "",
            identity: nil,
            phase: :idle

  @impl true
  def init(_children, attrs, previous) do
    identity = Map.get(attrs, :"effect-identity")
    previous = previous || %{}

    started_ms =
      if Map.get(previous, :identity) == identity do
        Map.get(previous, :started_ms, System.monotonic_time(:millisecond))
      else
        System.monotonic_time(:millisecond)
      end

    state = %__MODULE__{
      kind: Map.fetch!(attrs, :"effect-kind"),
      started_ms: Map.get(attrs, :"effect-started-ms", started_ms),
      enabled?: Map.get(attrs, :"effect-enabled", false),
      skip?: Map.get(attrs, :"effect-skip", false),
      ascii?: Map.get(attrs, :"effect-ascii", false),
      width_count: attrs |> Map.get(:"effect-width", 24) |> max(1) |> min(@max_width_count),
      rows_count: attrs |> Map.get(:"effect-rows", 1) |> max(1) |> min(5),
      clip: Map.get(attrs, :"effect-clip", {0, 0, 0, 0}),
      text: Map.get(attrs, :"effect-text", ""),
      identity: identity,
      phase: Map.get(attrs, :"effect-phase", :idle)
    }

    options =
      if state.enabled? and not (state.kind == :logo and state.skip?),
        do: [rerender_every: @frame_ms],
        else: []

    {:ok, state, options}
  end

  @impl true
  def handle_modifiers(_type, _flags, _state), do: []

  @impl true
  def animate(:child, box, _flags, _state, _context), do: box

  def animate(:root, box, _flags, state, context) do
    elapsed_ms = max((context.now || state.started_ms) - state.started_ms, 0)
    frame = if state.enabled?, do: div(elapsed_ms, @frame_ms), else: 0
    animated = %{box | content: content(state, frame, elapsed_ms)}
    present(animated, box, state, context)
  end

  # A fragment's inherited ANSI styling need not appear byte-for-byte in its
  # parent's raster. Position overlays explicitly instead of replacing strings.
  defp present(animated, original, state, %{phase: :async, layout: %Breeze.Viewport{} = layout}) do
    width = min(layout.width || 0, @max_width_count)
    height = min(layout.height, 7)
    overlays = overlay_rows(animated, layout, state.clip, width, height)
    {:ok, original, overlays: overlays}
  end

  defp present(animated, _original, _state, _context), do: animated

  defp overlay_rows(_box, _layout, _clip, width, height) when width <= 0 or height <= 0, do: []

  defp overlay_rows(box, layout, {left, top, right, bottom}, width, height) do
    x = max(layout.left, max(left, 0))
    visible_width = max(min(layout.left + width, right) - x, 0)
    clipped_rows(box, layout, {x, top, bottom}, {width, visible_width, height})
  end

  defp clipped_rows(_box, _layout, _bounds, {_width, 0, _height}), do: []

  defp clipped_rows(box, layout, {x, top, bottom}, {width, visible_width, height}) do
    terminal = %Termite.Terminal{size: %{width: visible_width, height: height}}
    content = box.content |> String.split("\n") |> Enum.take(height)
    offset = x - layout.left
    content = Enum.map_join(content, "\n", &slice_cells(&1, offset, min(width, visible_width)))

    box = %{
      box
      | state: :ready,
        content: content,
        style: %{box.style | width: visible_width, height: height}
    }

    rendered = BackBreeze.Box.render(box, terminal: terminal)

    rendered.content
    |> String.split("\n")
    |> Enum.take(height)
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      y = layout.top + index

      if y >= max(top, 0) and y < bottom,
        do: [%{x: x, y: y, content: line, no_wrap: true}],
        else: []
    end)
  end

  defp slice_cells(text, offset, width) do
    {parts, _cells} =
      text
      |> String.graphemes()
      |> Enum.map_reduce(0, fn glyph, position ->
        cells = max(BackBreeze.Ucwidth.width(glyph), 0)
        visible = max(min(position + cells, offset + width) - max(position, offset), 0)

        part =
          if visible > 0 and visible == cells, do: glyph, else: String.duplicate(" ", visible)

        {part, position + cells}
      end)

    IO.iodata_to_binary(parts)
  end

  defp content(%{kind: :logo} = state, frame, elapsed_ms) do
    cond do
      not state.enabled? or state.skip? -> state.text
      elapsed_ms < @entrance_ms -> resolve_logo(state.text, frame, elapsed_ms)
      rem(frame, 120) == 119 -> String.replace(state.text, "▀", "░")
      true -> state.text
    end
  end

  defp content(%{kind: :scanner} = state, frame, _elapsed_ms) do
    scanner(state, frame)
  end

  defp content(%{kind: :blackwall} = state, frame, elapsed_ms) do
    elapsed_ms = if state.enabled?, do: elapsed_ms, else: 0
    Enum.map_join(0..(state.rows_count - 1), "\n", &wall_row(state, {frame, elapsed_ms}, &1))
  end

  defp content(%{kind: :emblem, ascii?: true}, frame, _elapsed_ms) do
    "    /------------\\\n   /    [ " <>
      elem(@glyphs, rem(frame, 6)) <>
      " ]   \\\n  <    REYCODE     >\n   \\            /\n    \\----------/"
  end

  defp content(%{kind: :emblem, enabled?: enabled?}, frame, _elapsed_ms) do
    Enum.map_join(0..6, "\n", fn index ->
      line = elem(@emblem, index)

      if enabled? and rem(frame, 18) == index,
        do: String.replace(line, "─", "━"),
        else: line
    end)
  end

  defp content(%{kind: :signal} = state, frame, _elapsed_ms) do
    levels = if state.ascii?, do: {".", ":", "|", "#"}, else: {"▁", "▃", "▅", "▇"}

    Enum.map_join(0..(state.width_count - 1), fn index ->
      elem(levels, Integer.mod(index * 7 + div(frame + index, 3), tuple_size(levels)))
    end)
  end

  # The relic tag: a session's hex identity. Its digits roll while a message
  # is being accepted and resolve left to right as the work settles.
  defp content(%{kind: :tag, enabled?: false} = state, _frame, _elapsed_ms), do: state.text

  defp content(%{kind: :tag, phase: :breach} = state, frame, _elapsed_ms),
    do: roll_tag(state.text, frame, 0)

  defp content(%{kind: :tag, phase: :settling} = state, frame, elapsed_ms) do
    revealed = div(String.length(state.text) * elapsed_ms, Blackwall.settle_ms())
    roll_tag(state.text, frame, revealed)
  end

  defp content(%{kind: :tag} = state, _frame, _elapsed_ms), do: state.text

  # The "0x" prefix and every revealed digit stay put; the rest roll as hex.
  defp roll_tag(text, frame, revealed_count) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join(fn
      {glyph, index} when index < 2 or index < revealed_count -> glyph
      {_glyph, index} -> hex_cell({:tag, index + frame}, index)
    end)
  end

  defp scanner(state, frame) do
    position = Integer.mod(frame, state.width_count + 5)
    dim = if state.ascii?, do: "-", else: "─"
    trail = if state.ascii?, do: "=", else: "━"
    head = if state.ascii?, do: ">", else: "◆"

    Enum.map_join(0..(state.width_count - 1), fn index ->
      cond do
        index == position -> head
        index in (position - 3)..(position - 1) -> trail
        true -> dim
      end
    end)
  end

  # Every phase without a live clock renders still; only moving work sweeps.
  @still_phases [:idle, :blocked, :failed, :cancelled, :completed]

  # One-row boundary: a still rule while idle, Breach Protocol hex while a
  # message is being accepted, then an upload sweep while work moves.
  defp wall_row(%{rows_count: 1} = state, {frame, elapsed_ms}, _row),
    do: strip_row(state, frame, elapsed_ms)

  # Multi-row boundary: a Blackwall hex matrix. Still when idle, ICE cells
  # flash through it during a breach, and bytes tick while data streams.
  defp wall_row(state, {frame, elapsed_ms}, row), do: field_row(state, frame, elapsed_ms, row)

  defp strip_glyphs(true), do: {"-", "=", ">"}
  defp strip_glyphs(false), do: {"─", "━", "◆"}
  defp broken_rule(true), do: "-"
  defp broken_rule(false), do: "╌"
  defp ice_glyph(true), do: "#"
  defp ice_glyph(false), do: "▓"
  defp dim_glyph(true), do: ":"
  defp dim_glyph(false), do: "▒"

  defp strip_row(%{phase: :breach} = state, frame, _elapsed_ms) do
    head = if state.ascii?, do: ">", else: "▸"
    position = Integer.mod(frame * 2, state.width_count + 5)

    Enum.map_join(0..(state.width_count - 1), fn index ->
      if index == position, do: head, else: hex_cell({:strip, div(index, 3) + frame}, index)
    end)
  end

  defp strip_row(%{phase: :settling} = state, _frame, elapsed_ms) do
    {rule, trail, _head} = strip_glyphs(state.ascii?)
    settled = div(elapsed_ms * state.width_count, Blackwall.settle_ms())
    Enum.map_join(0..(state.width_count - 1), &if(&1 < settled, do: rule, else: trail))
  end

  # A failed or cancelled turn leaves a broken rule behind it.
  defp strip_row(%{phase: phase} = state, _frame, _elapsed_ms)
       when phase in [:failed, :cancelled],
       do: String.duplicate(broken_rule(state.ascii?), state.width_count)

  defp strip_row(%{phase: phase} = state, _frame, _elapsed_ms) when phase in @still_phases,
    do: state.ascii? |> strip_glyphs() |> elem(0) |> String.duplicate(state.width_count)

  defp strip_row(state, frame, _elapsed_ms) do
    {rule, trail, head} = strip_glyphs(state.ascii?)
    position = Integer.mod(frame, state.width_count + 5)

    Enum.map_join(0..(state.width_count - 1), fn index ->
      cond do
        index == position -> head
        index in (position - 3)..(position - 1) -> trail
        true -> rule
      end
    end)
  end

  defp field_row(%{phase: :settling} = state, _frame, elapsed_ms, row) do
    settled = div(elapsed_ms * state.width_count, Blackwall.settle_ms())

    Enum.map_join(0..(state.width_count - 1), fn index ->
      cond do
        rem(index, 3) == 2 -> " "
        index < settled -> hex_cell({:field, div(index, 3), row, 0}, index)
        true -> dim_glyph(state.ascii?)
      end
    end)
  end

  defp field_row(state, frame, _elapsed_ms, row) do
    density = wall_density(state.phase)
    frame = if state.phase in @still_phases, do: 0, else: frame

    Enum.map_join(0..(state.width_count - 1), fn index ->
      slot = div(index, 3)
      offset = Integer.mod(slot * 7 + row * 3 + div(frame, 2), density)

      cond do
        rem(index, 3) == 2 -> " "
        frame > 0 and offset == 0 -> ice_glyph(state.ascii?)
        frame > 0 and offset == 1 -> dim_glyph(state.ascii?)
        true -> hex_cell({:field, slot, row, 0}, index)
      end
    end)
  end

  defp wall_density(:breach), do: 3
  defp wall_density(:receiving), do: 17
  defp wall_density(_phase), do: 11

  # One hex digit of a deterministic byte; the seed fixes the byte, the cell's
  # position within its 3-cell slot picks the high or low digit.
  defp hex_cell(seed, index), do: seed |> hex_byte() |> String.at(rem(index, 3))

  defp hex_byte(seed) do
    seed |> :erlang.phash2(256) |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end

  defp resolve_logo(text, frame, elapsed_ms),
    do: resolve_logo(text, frame, elapsed_ms, @entrance_ms)

  defp resolve_logo(text, frame, elapsed_ms, duration_ms) do
    glyphs = String.graphemes(text)
    revealed_count = div(length(glyphs) * elapsed_ms, duration_ms)

    glyphs
    |> Enum.with_index()
    |> Enum.map_join(fn {glyph, index} ->
      if glyph in [" ", "\n"] or index < revealed_count,
        do: glyph,
        else: elem(@glyphs, rem(index + frame, tuple_size(@glyphs)))
    end)
  end
end
