defmodule ReyCode.TUI.TextSelection do
  @moduledoc "Owns transcript drag gestures, stable highlights, and copy-on-release."

  alias BackBreeze.{TextSpan, Ucwidth}
  alias Breeze.{Component, View, Viewport}
  alias ReyCode.TUI.{Clipboard, Notice, State}
  alias ReyCode.TUI.Components.MainScreen.Timeline

  @max_selection_bytes 1_000_000
  @max_selection_row_count 10_000
  @edge_interval_ms 80
  @max_drag_ms 120_000
  defstruct [
    :anchor,
    :endpoint,
    :messages,
    :rows,
    :row_index,
    :session_id,
    :size,
    :pointer,
    :timeline_id,
    :scroll_offset,
    :token,
    :started_ms,
    dragging?: true,
    moved?: false
  ]

  @doc "Routes a complete gesture before nested controls consume pointer events."
  def intercept(event, term) do
    term = validate_context(term)
    selection = Map.get(term.assigns, :text_selection)

    case Map.get(term.assigns, :selection_click) do
      nil -> intercept(event, selection, term)
      click -> click_event(event, click, term)
    end
  end

  defp intercept(%{"mouse" => %{"button" => "left", "action" => "press"} = mouse}, _, term),
    do: begin_selection(mouse, clear(term))

  defp intercept(%{"mouse" => mouse}, %__MODULE__{dragging?: true} = selection, term),
    do: drag(mouse, selection, term)

  defp intercept(event, %__MODULE__{}, term) when event in ["Escape", "Esc"],
    do: {:halt, clear(term)}

  defp intercept(%{"key" => key}, %__MODULE__{}, term) when key in ["Escape", "Esc"],
    do: {:halt, clear(term)}

  defp intercept(_event, %__MODULE__{dragging?: true}, term), do: {:cont, clear(term)}
  defp intercept(_event, _selection, term), do: {:cont, term}

  @doc "Cancels a selection when the viewport or session changes."
  def clear(term), do: Component.assign(term, text_selection: nil, selection_click: nil)

  defp validate_context(term) do
    case Map.get(term.assigns, :text_selection) do
      %__MODULE__{session_id: id, size: size} ->
        if id == term.assigns.selected_session_id and size == term.assigns.breeze.terminal and
             term.assigns.modal in [nil, :operator_question],
           do: term,
           else: clear(term)

      nil ->
        term
    end
  end

  defp click_event(%{"mouse" => %{"action" => "release"} = mouse}, click, term) do
    term = clear(term)

    if not Map.get(click, "moved", false) and same_position?(mouse, click),
      do: {:cont, %{"mouse" => click}, term},
      else: {:halt, term}
  end

  defp click_event(%{"mouse" => %{"action" => "move"} = mouse}, click, term) do
    click =
      Map.put(click, "moved", Map.get(click, "moved", false) or not same_position?(mouse, click))

    {:halt, Component.assign(term, selection_click: click)}
  end

  defp click_event(event, _click, term), do: intercept(event, nil, clear(term))

  defp same_position?(a, b),
    do: Map.fetch!(a, "x") == Map.fetch!(b, "x") and Map.fetch!(a, "y") == Map.fetch!(b, "y")

  @doc "Keeps the gesture's text stable while provider events continue to arrive."
  def prepare(assigns) do
    case Map.get(assigns, :text_selection) do
      %__MODULE__{session_id: id, size: size} = selection ->
        if id == assigns.selected_session_id and size == assigns.breeze.terminal do
          freeze(assigns, selection)
        else
          Map.put(assigns, :text_selection, nil)
        end

      nil ->
        Map.put(assigns, :text_selection, nil)
    end
  end

  defp freeze(assigns, %{dragging?: true, messages: messages}),
    do: Map.put(assigns, :messages, messages)

  defp freeze(assigns, %{messages: messages}) do
    if messages == assigns.messages, do: assigns, else: Map.put(assigns, :text_selection, nil)
  end

  @doc "Adds stable line IDs and Unicode cell-aware selection highlighting."
  def decorate(lines, message_id, selection) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      id = "selection-#{message_id}-#{index}"
      Map.merge(line, %{id: id, spans: highlight(line.spans, id, selection)})
    end)
  end

  @doc "Wraps long code and words by terminal cells without adding copy newlines."
  def wrap_lines(lines, width) do
    Enum.flat_map(lines, fn line ->
      if Enum.sum(Enum.map(line.spans, &text_width(&1.text))) <= width,
        do: [line],
        else: wrap_line(line, width)
    end)
  end

  defp wrap_line(line, width) do
    graphemes =
      Enum.flat_map(line.spans, fn span ->
        Enum.map(String.graphemes(span.text), &%TextSpan{text: &1, style: span.style})
      end)

    {rows, current, _cells} = Enum.reduce(graphemes, {[], [], 0}, &wrap_grapheme(&1, &2, width))

    Enum.reverse([%{line | spans: Enum.reverse(current)} | rows])
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      Map.put(row, :copy_skip, if(index == 0, do: Map.get(line, :copy_skip, 0), else: 0))
    end)
  end

  defp wrap_grapheme(span, {rows, current, cells}, width) do
    count = max(Ucwidth.width(span.text), 0)

    if cells > 0 and cells + count > width,
      do: {[%{spans: Enum.reverse(current), separator: ""} | rows], [span], count},
      else: {rows, [span | current], cells + count}
  end

  @doc "Extracts exactly the selected graphemes, with logical rather than soft-wrap separators."
  def text(%__MODULE__{anchor: anchor, endpoint: endpoint, rows: rows}) do
    {first, last} = ordered(anchor, endpoint)

    rows
    |> Enum.with_index()
    |> Enum.filter(fn {_row, index} -> index >= elem(first, 0) and index <= elem(last, 0) end)
    |> Enum.map(fn {row, index} ->
      from = if index == elem(first, 0), do: elem(first, 1), else: 0
      from = max(from, Map.get(row, :copy_skip, 0))
      until = if index == elem(last, 0), do: elem(last, 1), else: String.length(row.text)
      separator = if index == elem(last, 0), do: "", else: row.separator
      String.slice(row.text, from, max(until - from, 0)) <> separator
    end)
    |> IO.iodata_to_binary()
  end

  defp begin_selection(mouse, term) do
    assigns = State.prepare_render(term.assigns)
    rows = transcript_rows(assigns)
    layouts = View.element_layouts(term)

    viewport = Map.get(layouts, assigns.timeline_id)

    point =
      if assigns.modal in [nil, :operator_question] and inside?(viewport, mouse),
        do: hit(rows, layouts, mouse, false)

    case point do
      nil -> {:halt, Component.assign(term, selection_click: mouse)}
      point -> capture(point, rows, mouse, assigns, term)
    end
  end

  defp capture(point, rows, mouse, assigns, term) do
    if length(rows) > @max_selection_row_count or
         Enum.reduce(rows, 0, &(byte_size(&1.text) + byte_size(&1.separator) + &2)) >
           @max_selection_bytes do
      {:halt,
       Component.assign(term, notice: Notice.new(:warning, "Transcript too large to select"))}
    else
      offset = View.scroll_offset_y(term, assigns.timeline_id)

      selection = %__MODULE__{
        anchor: point,
        endpoint: point,
        rows: rows,
        row_index: Map.new(Enum.with_index(rows), fn {row, index} -> {row.id, index} end),
        messages: assigns.messages,
        session_id: assigns.selected_session_id,
        size: assigns.breeze.terminal,
        pointer: mouse,
        timeline_id: assigns.timeline_id,
        scroll_offset: offset,
        token: make_ref(),
        started_ms: System.monotonic_time(:millisecond)
      }

      term =
        View.update_implicit(term, assigns.timeline_id, fn {_module, state} ->
          %{state | offset_y: offset, pinned_bottom: false}
        end)

      schedule_edge(selection)
      {:halt, Component.assign(term, text_selection: selection)}
    end
  end

  defp transcript_rows(assigns) do
    assigns.messages
    |> Enum.filter(&(&1.kind == :message and &1.body != ""))
    |> Enum.flat_map(fn message ->
      message
      |> Timeline.selection_lines(assigns.message_width, nil)
      |> Enum.map(fn row ->
        Map.put(row, :text, String.trim_trailing(Enum.map_join(row.spans, & &1.text)))
      end)
      |> append_message_break()
    end)
  end

  defp append_message_break(rows) do
    List.update_at(rows, -1, &%{&1 | separator: "\n\n"})
  end

  defp drag(%{"button" => button} = mouse, selection, term)
       when button in ["wheel_up", "wheel_down"] do
    delta = if button == "wheel_up", do: -3, else: 3
    {:halt, scroll(term, selection, mouse, delta)}
  end

  defp drag(%{"action" => action} = mouse, selection, term)
       when action in ["move", "release"] do
    point = selection_point(selection, term, mouse)
    moved = selection.moved? or point != selection.anchor
    selection = %{selection | endpoint: point, pointer: mouse, moved?: moved}
    term = Component.assign(term, text_selection: selection)

    if action == "release" do
      finish(selection, term)
    else
      {:halt, term}
    end
  end

  defp drag(_mouse, _selection, term), do: {:halt, term}

  defp finish(%{moved?: false}, term), do: {:halt, clear(term)}

  defp finish(selection, term) do
    selected = text(selection)
    copy = Map.get(term.assigns, :selection_copy, &Clipboard.copy/1)
    notice = copy_notice(selected, copy)

    {:halt,
     Component.assign(term, text_selection: %{selection | dragging?: false}, notice: notice)}
  end

  defp copy_notice("", _copy), do: nil

  defp copy_notice(text, copy) do
    case copy.(text) do
      :ok -> Notice.new(:success, "Selection copied")
      {:error, reason} -> Notice.new(:error, "Could not copy selection: #{inspect(reason)}")
    end
  end

  @doc "Advances bounded edge scrolling while the pointer remains outside the transcript."
  def tick(term, token) do
    term = validate_context(term)

    case Map.get(term.assigns, :text_selection) do
      %__MODULE__{dragging?: true, token: ^token} = selection -> tick_selection(term, selection)
      _ -> term
    end
  end

  defp tick_selection(term, selection) do
    if System.monotonic_time(:millisecond) - selection.started_ms >= @max_drag_ms do
      clear(term)
    else
      schedule_edge(selection)
      edge_scroll(term, selection)
    end
  end

  defp edge_scroll(term, selection) do
    delta = edge_delta(term, selection)
    if delta == 0, do: term, else: scroll(term, selection, selection.pointer, delta)
  end

  defp schedule_edge(selection),
    do: Process.send_after(self(), {:selection_edge, selection.token}, @edge_interval_ms)

  defp edge_delta(term, selection) do
    viewport = Map.get(View.element_layouts(term), selection.timeline_id)
    y = Map.fetch!(selection.pointer, "y")

    cond do
      is_nil(viewport) -> 0
      y <= viewport.top -> -1
      y >= viewport.top + viewport.height - 1 -> 1
      true -> 0
    end
  end

  defp scroll(term, selection, mouse, delta) do
    viewport = Map.fetch!(View.element_layouts(term), selection.timeline_id)

    offset =
      Viewport.clamp_scroll_y(View.scroll_offset_y(term, selection.timeline_id) + delta, viewport)

    term =
      View.update_implicit(term, selection.timeline_id, fn {_module, state} ->
        %{state | offset_y: offset, pinned_bottom: false}
      end)

    selection = %{selection | pointer: mouse, scroll_offset: offset}
    point = selection_point(selection, term, mouse)

    selection = %{
      selection
      | endpoint: point,
        moved?: selection.moved? or point != selection.anchor
    }

    Component.assign(term, text_selection: selection)
  end

  defp inside?(nil, _mouse), do: false

  defp inside?(box, mouse) do
    x = Map.fetch!(mouse, "x")
    y = Map.fetch!(mouse, "y")
    x >= box.left and x < box.left + box.width and y >= box.top and y < box.top + box.height
  end

  defp selection_point(selection, term, mouse) do
    layouts = View.element_layouts(term)
    viewport = Map.fetch!(layouts, selection.timeline_id)

    mouse =
      Map.update!(mouse, "y", &min(max(&1, viewport.top), viewport.top + viewport.height - 1))

    hit(selection.rows, layouts, mouse, true) || selection.endpoint
  end

  defp hit(rows, layouts, mouse, clamp?) do
    x = Map.fetch!(mouse, "x")
    y = Map.fetch!(mouse, "y")

    candidates =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, index} ->
        case Map.get(layouts, row.id) do
          nil -> []
          box -> [{row, index, box}]
        end
      end)

    candidate =
      if clamp? do
        Enum.min_by(candidates, fn {_row, _index, box} -> abs(y - box.top) end, fn -> nil end)
      else
        Enum.find(candidates, fn {row, _index, box} ->
          y == box.top and x >= box.left and x < box.left + text_width(row.text)
        end)
      end

    case candidate do
      nil -> nil
      {row, index, box} -> {index, column_index(row.text, max(x - box.left, 0))}
    end
  end

  defp column_index(text, column) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, 0}, fn grapheme, {index, cell} ->
      width = max(Ucwidth.width(grapheme), 0)

      if cell + width > column,
        do: {:halt, {index, cell}},
        else: {:cont, {index + 1, cell + width}}
    end)
    |> elem(0)
  end

  defp text_width(text),
    do: text |> String.graphemes() |> Enum.reduce(0, &(max(Ucwidth.width(&1), 0) + &2))

  defp highlight(spans, _id, nil), do: spans

  defp highlight(spans, id, selection) do
    index = row_index(selection, id)
    {first, last} = ordered(selection.anchor, selection.endpoint)

    if is_nil(index) or index < elem(first, 0) or index > elem(last, 0),
      do: spans,
      else: highlight_range(spans, index, {first, last})
  end

  defp row_index(%{row_index: nil, rows: rows}, id), do: Enum.find_index(rows, &(&1.id == id))
  defp row_index(%{row_index: index}, id), do: Map.get(index, id)

  defp highlight_range(spans, index, {first, last}) do
    {spans, _offset} =
      Enum.map_reduce(spans, 0, fn span, offset ->
        parts = highlight_span(span, offset, index, {first, last})

        {parts, offset + String.length(span.text)}
      end)

    List.flatten(spans)
  end

  defp highlight_span(span, offset, index, {first, last}) do
    span.text
    |> String.graphemes()
    |> Enum.with_index(offset)
    |> Enum.map(fn {text, pos} ->
      style =
        if index && {index, pos} >= first && {index, pos} < last,
          do: Map.merge(span.style, %{reverse: true}),
          else: span.style

      %TextSpan{text: text, style: style}
    end)
  end

  defp ordered(a, b) when a <= b, do: {a, b}
  defp ordered(a, b), do: {b, a}
end
