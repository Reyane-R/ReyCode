defmodule ReyCode.TUI.EffectsTest do
  use ExUnit.Case, async: true

  alias BackBreeze.{Box, Ucwidth}
  alias ReyCode.TUI.Effects

  test "logo resolves by deadline without moving its cells and typing skips it" do
    text = "█▀ REYCODE\n  █▀▀"
    {state, options} = effect(:logo, %{"effect-text": text})
    assert options == [rerender_every: 100]
    initial = animate(state, 0)
    middle = animate(state, 400)
    assert initial.content != middle.content
    assert animate(state, 700).content == text
    assert animate(state, 11_900).content != text
    assert animate(state, 12_000).content == text

    for frame <- [initial, middle] do
      assert line_widths(frame.content) == line_widths(text)
    end

    {skipped, []} = effect(:logo, %{"effect-text": text, "effect-skip": true})
    assert animate(skipped, 0).content == text
  end

  test "decoration reconciliation preserves phase until its identity changes" do
    {state, _options} = effect(:scanner, %{"effect-identity": :settings})
    state = %{state | started_ms: 123}
    attrs = %{"effect-kind": :scanner, "effect-enabled": true, "effect-identity": :settings}
    assert {:ok, %{started_ms: 123}, _options} = Effects.init([], attrs, state)

    assert {:ok, changed, _options} =
             Effects.init([], %{attrs | "effect-identity": :help}, state)

    refute changed.started_ms == 123
  end

  test "scanners and signals animate inside a bounded cell budget" do
    for kind <- [:scanner, :signal], ascii? <- [true, false], width <- [1, 24, 10_000] do
      {state, _options} = effect(kind, %{"effect-width": width, "effect-ascii": ascii?})

      frames = Enum.map([0, 300, 800], &animate(state, &1).content)
      assert Enum.all?(frames, &(cell_width(&1) == min(width, 160)))
      assert length(Enum.uniq(frames)) > 1
      if ascii?, do: assert(Enum.all?(frames, &(byte_size(&1) == String.length(&1))))
    end
  end

  test "reduced motion registers no decoration timer and every effect stays still" do
    for kind <- [:logo, :scanner, :signal, :emblem, :blackwall],
        ascii? <- [true, false] do
      {state, []} =
        effect(kind, %{"effect-enabled": false, "effect-ascii": ascii?, "effect-text": "REYCODE"})

      assert animate(state, 0) == animate(state, 10_000)
    end
  end

  test "links, attention brackets and emblem change without changing dimensions" do
    for kind <- [:emblem], ascii? <- [true, false] do
      {state, _options} = effect(kind, %{"effect-ascii": ascii?})
      first = animate(state, 0)
      second = animate(state, 700)
      refute first.content == second.content
      assert line_widths(first.content) == line_widths(second.content)
      assert first.style == second.style
    end
  end

  test "Blackwall interference is bounded, ASCII safe, and static when disabled" do
    for phase <- [:breach, :waiting, :receiving, :working, :settling],
        ascii? <- [true, false],
        width <- [1, 26, 10_000] do
      attrs = %{
        "effect-phase": phase,
        "effect-ascii": ascii?,
        "effect-width": width,
        "effect-rows": 20
      }

      {state, _} = effect(:blackwall, attrs)
      frames = Enum.map([0, 300, 700], &animate(state, &1).content)
      assert Enum.all?(frames, &(line_widths(&1) == List.duplicate(min(width, 160), 5)))
      assert length(Enum.uniq(frames)) > 1
      if ascii?, do: assert(Enum.all?(frames, &(byte_size(&1) == String.length(&1))))
      {static, []} = effect(:blackwall, Map.put(attrs, :"effect-enabled", false))
      assert animate(static, 0) == animate(static, 10_000)
    end
  end

  test "decorations never alter child content or input modifiers" do
    {state, _options} = effect(:scanner)
    box = %Box{content: "keep this draft"}
    assert Effects.animate(:child, box, [], state, %{}) == box
    assert Effects.handle_modifiers(:root, [], state) == []
  end

  test "async effects emit positioned rows clipped away from headers and the composer" do
    {state, _options} = effect(:emblem, %{"effect-clip": {0, 2, 80, 4}})
    box = %Box{content: "base raster"}
    layout = %Breeze.Viewport{left: 3, top: 1, width: 24, height: 7}
    context = %{phase: :async, now: state.started_ms + 500, layout: layout}
    assert {:ok, ^box, overlays: rows} = Effects.animate(:root, box, [], state, context)
    assert Enum.map(rows, &{&1.x, &1.y}) == [{3, 2}, {3, 3}]
    assert Enum.all?(rows, & &1.no_wrap)

    for layout <- [%{layout | width: 0}, %{layout | top: 100}, %{layout | left: 81}] do
      assert {:ok, ^box, overlays: []} =
               Effects.animate(:root, box, [], state, %{context | layout: layout})
    end
  end

  test "async rows are cropped to both edges of their parent in terminal cells" do
    {state, _options} = effect(:signal, %{"effect-clip": {2, 0, 10, 3}, "effect-width": 20})
    box = %Box{}

    for left <- [-5, 0, 5, 9] do
      layout = %Breeze.Viewport{left: left, top: 0, width: 20, height: 1}
      context = %{phase: :async, now: state.started_ms + 500, layout: layout}
      assert {:ok, ^box, overlays: [row]} = Effects.animate(:root, box, [], state, context)
      text = String.replace(row.content, ~r/\e\[[0-9;]*m/, "")
      assert row.x == max(left, 2)
      assert cell_width(text) == 10 - row.x
    end
  end

  defp effect(kind, overrides \\ %{}) do
    attrs = Map.merge(%{"effect-kind": kind, "effect-enabled": true}, overrides)
    {:ok, state, options} = Effects.init([], attrs, nil)
    {state, options}
  end

  defp animate(state, elapsed_ms) do
    Effects.animate(:root, %Box{}, [], state, %{now: state.started_ms + elapsed_ms})
  end

  defp line_widths(text), do: text |> String.split("\n") |> Enum.map(&cell_width/1)

  defp cell_width(text),
    do: text |> String.graphemes() |> Enum.reduce(0, &(Ucwidth.width(&1) + &2))
end
