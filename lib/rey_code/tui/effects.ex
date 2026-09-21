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

  defp content(%{kind: :link, ascii?: true}, frame, _elapsed_ms),
    do: elem({"--o---->", "---o--->", "----o-->", "-----o->"}, rem(frame, 4))

  defp content(%{kind: :link}, frame, _elapsed_ms),
    do: elem({"──◆────▸", "───◆───▸", "────◆──▸", "─────◆─▸"}, rem(frame, 4))

  defp content(%{kind: :attention}, frame, _elapsed_ms),
    do: elem({"[ ! ]", "[ ! ]", "  !  ", "  !  "}, rem(div(frame, 3), 4))

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

  defp wall_glyphs(true), do: {"-", "/", ":"}
  defp wall_glyphs(false), do: {"─", "╱", "░"}

  defp wall_row(state, {frame, elapsed_ms}, row) do
    glyphs = wall_glyphs(state.ascii?)
    density = wall_density(state.phase)
    frame = if state.phase in [:idle, :blocked, :failed, :cancelled], do: 0, else: frame

    Enum.map_join(0..(state.width_count - 1), fn index ->
      offset = Integer.mod(index * 7 + row * 3 + div(frame, 2), density)

      wall_cell(state, glyphs, {index, offset}, elapsed_ms)
    end)
  end

  defp wall_density(:breach), do: 3
  defp wall_density(:receiving), do: 17
  defp wall_density(_phase), do: 11

  defp wall_cell(%{phase: :settling} = state, glyphs, {index, _offset}, elapsed_ms) do
    if index < div(elapsed_ms * state.width_count, Blackwall.settle_ms()),
      do: elem(glyphs, 0),
      else: elem(glyphs, 2)
  end

  defp wall_cell(_state, glyphs, {_index, 0}, _frame), do: elem(glyphs, 1)
  defp wall_cell(_state, glyphs, {_index, 1}, _frame), do: elem(glyphs, 2)

  defp wall_cell(state, glyphs, _position, _frame),
    do: if(state.rows_count > 1, do: " ", else: elem(glyphs, 0))

  defp resolve_logo(text, frame, elapsed_ms) do
    glyphs = String.graphemes(text)
    revealed_count = div(length(glyphs) * elapsed_ms, @entrance_ms)

    glyphs
    |> Enum.with_index()
    |> Enum.map_join(fn {glyph, index} ->
      if glyph in [" ", "\n"] or index < revealed_count,
        do: glyph,
        else: elem(@glyphs, rem(index + frame, tuple_size(@glyphs)))
    end)
  end
end
