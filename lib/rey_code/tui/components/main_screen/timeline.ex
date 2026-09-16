defmodule ReyCode.TUI.Components.MainScreen.Timeline do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  alias BackBreeze.{TextSpan, Ucwidth}
  alias ReyCode.Failure
  alias ReyCode.Orchestration.StrategicReview
  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.{Activity, MermaidASCII}

  @max_visible_notes 8

  defmodule Disclosure do
    @moduledoc false
    @behaviour Breeze.Implicit

    @impl true
    def init(_children, attrs, _previous),
      do:
        {:ok,
         %{
           message_id: Map.fetch!(attrs, :message_id),
           timeline_id: Map.fetch!(attrs, :timeline_id)
         }}

    @impl true
    def handle_event(_, %{"key" => key}, state) when key in ["Enter", " "],
      do: {{:change, %{message_id: state.message_id}}, state}

    def handle_event(_, %{"mouse" => %{"button" => "left", "action" => "press"}}, state),
      do: {{:change, %{message_id: state.message_id}}, state}

    def handle_event(_, %{"key" => key}, state)
        when key in ["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", "j", "k"],
        do: {{:delegate, state.timeline_id}, state}

    def handle_event(_, %{"mouse" => %{"button" => button}}, state)
        when button in ["wheel_up", "wheel_down"],
        do: {{:delegate, state.timeline_id}, state}

    def handle_event(_, _, state), do: {:noreply, state}

    @impl true
    def handle_modifiers(_, _, _), do: []
  end

  attr :messages, :list, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :activity_frame, :string, required: true
  attr :terminal_height, :integer
  attr :challenge_enabled, :boolean

  def timeline(assigns) do
    assigns = Map.put_new(assigns, :terminal_height, 40)
    assigns = Map.put_new(assigns, :challenge_enabled, true)
    # Keep vertical padding in the content so Breeze includes it in scroll bounds.
    ~H"""
    <.scroll
      id={@timeline_id}
      scroll-autoscroll="bottom"
      class="h-full w-full border-none overflow-scroll mute-scrollbar-40 px-2"
    >
      <box class="w-full py-1">
        <box :if={@messages == []} class="pt-4 w-full">
          <box class="font-bold text-primary">Ready</box>
          <box class="pt-1 text-muted">
            Message the Assistant or delegate focused work with /task.
          </box>
        </box>
        <box :for={{item, index} <- Enum.with_index(@messages)} class="w-full">
          <box :if={item.kind == :context_boundary} class="w-full py-1 text-warning">
            Context compacted · /context to inspect
            <box class="pl-2 text-muted">{boundary_preview(item.summary)}</box>
          </box>
          <box :if={item.kind == :message} class={message_class(item, index, @terminal_height)}>
            <box class="inline w-full overflow-hidden">
              <box class={author_name_class(item)}>{author_label(item)}</box>
              <box :if={message_metadata(item) != ""} class="text-muted">{metadata_label(item)}</box>
              <box class={message_status_class(item)}>{message_status_label(item)}</box>
              <box
                :if={item.role == :assistant and item.body != ""}
                id={"copy-#{item.id}"}
                implicit={Disclosure}
                focusable
                message_id={item.id}
                timeline_id={@timeline_id}
                br-change="copy_answer"
                class="w-full text-right text-muted focus:text-primary"
              >
                Copy
              </box>
              <box
                :if={@challenge_enabled and challengeable?(item)}
                id={"challenge-#{item.id}"}
                implicit={Disclosure}
                focusable
                message_id={item.id}
                timeline_id={@timeline_id}
                br-change="challenge_message"
                class="pl-2 text-muted focus:text-primary"
              >
                Challenge
              </box>
            </box>
            <box
              :if={collapsible?(item)}
              id={"execution-details-#{item.id}"}
              implicit={Disclosure}
              focusable
              message_id={item.id}
              timeline_id={@timeline_id}
              br-change="execution_details_toggle"
              class="pl-2 w-full text-muted focus:text-primary"
            >
              {disclosure_label(item)}
            </box>
            <box
              :if={details_visible?(item) and note_overflow(item) > 0}
              class="pl-2 w-full text-muted"
            >
              +{note_overflow(item)} earlier thoughts
            </box>
            <box
              :for={row <- visible_execution_rows(item, @activity_frame, @message_width)}
              class="w-full"
            >
              <box class={row.class}>{row.text}</box>
              <box :for={line <- row.diff_lines} class={diff_line_class(line)}>{line}</box>
              <box :if={row.diff_truncated?} class="pl-4 w-full text-muted">
                … Diff preview truncated · /runs to inspect
              </box>
            </box>
            <box :if={item.body != ""} class={body_section_class(item, @terminal_height)}>
              <box
                :for={line <- render_message(item, @message_width)}
                class="pl-2 w-full overflow-hidden"
              >
                <box>{message_line(item, line)}</box>
              </box>
            </box>
            <box :if={show_placeholder?(item)} class="pl-2 w-full text-muted">
              {message_placeholder(item, @activity_frame)}
            </box>
            <box :if={item.error} class="pl-2 w-full overflow-hidden text-error">
              Error · {error_summary(item.error, @message_width)}
            </box>
          </box>
        </box>
      </box>
    </.scroll>
    """
  end

  defp boundary_preview(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 120)
  end

  defp render_message(message, width) do
    width = if message.role == :user, do: max(width - 2, 1), else: width

    message
    |> answer_text()
    |> MermaidASCII.expand()
    |> Breeze.Markdown.render(width)
    |> split_lines()
  end

  @doc "Returns the displayed answer's Markdown source, without activity or UI decoration."
  def answer_text(message), do: display_body(message)

  defp display_body(%{
         role: :assistant,
         status: :completed,
         turn: %{status: :terminal, outcome: :completed, strategy_review: packet},
         invocation: %{status: :completed},
         body: body
       })
       when not is_nil(packet),
       do: StrategicReview.render_output(body)

  defp display_body(message), do: message.body

  defp message_placeholder(%{activity: nil, status: :queued}, _frame), do: "Waiting…"
  defp message_placeholder(%{activity: nil}, frame), do: frame <> " · Thinking"

  defp message_placeholder(%{activity: activity}, frame),
    do: Activity.header_text(activity, frame)

  defp message_metadata(%{role: :user, created_at: created_at, turn: %{mode: :delegate}}) do
    [timestamp(created_at), "task"] |> Enum.reject(&(&1 == "")) |> Enum.join(" · ")
  end

  defp message_metadata(%{role: :user, created_at: created_at}), do: timestamp(created_at)

  defp message_metadata(%{invocation: invocation}) when not is_nil(invocation) do
    Presentation.short_runtime_label(invocation.participant)
  end

  defp message_metadata(_message), do: ""

  defp metadata_label(message), do: " · " <> message_metadata(message)

  defp author_label(%{role: :user}), do: "You"
  defp author_label(%{author: %{name: name}}), do: name

  defp challengeable?(%{
         role: :assistant,
         turn: %{status: :terminal, strategy_review: nil},
         body: body
       }),
       do: body != ""

  defp challengeable?(_item), do: false

  defp message_class(_message, 0, _height), do: "w-full overflow-hidden"

  defp message_class(%{role: :user}, _index, height) when height >= 32,
    do: "w-full pt-2 overflow-hidden"

  defp message_class(_message, _index, _height), do: "w-full pt-1 overflow-hidden"

  defp message_line(%{role: :user}, line), do: [%TextSpan{text: "│ ", style: %{}} | line]
  defp message_line(_message, line), do: line

  defp author_name_class(%{role: :user}), do: "font-bold text-secondary"
  defp author_name_class(%{author: %{id: "builder"}}), do: "font-bold text-primary"
  defp author_name_class(%{author: %{id: "critic"}}), do: "font-bold text-warning"
  defp author_name_class(_message), do: "font-bold text-primary"

  defp message_status_label(%{activity: activity}) do
    case Activity.badge(activity) do
      "" -> ""
      "completed" -> " · ✓"
      badge -> " · " <> String.capitalize(badge)
    end
  end

  defp message_status_class(%{activity: activity}),
    do: "text-#{Activity.color(activity)}"

  defp diff_line_class("+" <> _line), do: "pl-4 w-full text-success"
  defp diff_line_class("-" <> _line), do: "pl-4 w-full text-error"
  defp diff_line_class("@@" <> _line), do: "pl-4 w-full text-secondary"
  defp diff_line_class(_line), do: "pl-4 w-full text-muted"

  defp visible_execution_rows(item, frame, width) do
    if(details_visible?(item), do: item.execution_rows, else: [])
    |> drop_hidden_notes(visible_note_overflow(item.execution_rows))
    |> Enum.flat_map(&render_execution_row(&1, frame, width))
  end

  defp render_execution_row(%{kind: :note, text: text}, _frame, width) do
    text
    |> wrap_note(max(width - 2, 1))
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      trace_note(if(index == 0, do: "·", else: " "), line, "text-muted")
    end)
  end

  defp render_execution_row(row, frame, _width) do
    [
      %{
        class: "pl-2 w-full overflow-hidden text-#{Activity.color(row)}",
        text: Activity.text(row, frame),
        diff_lines: row.diff_lines,
        diff_truncated?: row.diff_truncated?
      }
    ]
  end

  defp wrap_note(text, width) do
    {rows, current} =
      text
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.reduce({[], ""}, &append_note_word(&1, &2, width))

    Enum.reverse(prepend_note_line(current, rows))
  end

  defp append_note_word(word, {rows, current}, width) do
    joined = if current == "", do: word, else: current <> " " <> word

    if cell_width(joined) <= width do
      {rows, joined}
    else
      word
      |> split_note_word(width)
      |> Enum.reduce({prepend_note_line(current, rows), ""}, fn part, {rows, current} ->
        {prepend_note_line(current, rows), part}
      end)
    end
  end

  defp prepend_note_line("", rows), do: rows
  defp prepend_note_line(line, rows), do: [line | rows]

  defp cell_width(text),
    do: text |> String.graphemes() |> Enum.reduce(0, &(Ucwidth.width(&1) + &2))

  defp split_note_word(word, width) do
    {rows, current, _cells} =
      Enum.reduce(String.graphemes(word), {[], [], 0}, fn char, {rows, current, cells} ->
        size = Ucwidth.width(char)

        if current != [] and cells + size > width,
          do: {[Enum.reverse(current) | rows], [char], size},
          else: {rows, [char | current], cells + size}
      end)

    [Enum.reverse(current) | rows] |> Enum.reverse() |> Enum.map(&Enum.join/1)
  end

  defp collapsible?(item) do
    item.status == :completed and is_nil(item.error) and item.execution_rows != [] and
      not active_message?(item) and
      Enum.all?(item.execution_rows, fn
        %{kind: :note} -> true
        %{state: :terminal, outcome: :completed} -> true
        _row -> false
      end)
  end

  defp details_visible?(item),
    do: not collapsible?(item) or Map.get(item, :execution_details_expanded?, false)

  defp disclosure_label(item) do
    action = if details_visible?(item), do: "Hide details", else: "Show details"

    case Enum.count(item.execution_rows, &(&1.kind == :tool)) do
      0 -> "Thinking · " <> action
      1 -> "1 tool action · " <> action
      count -> "#{count} tool actions · " <> action
    end
  end

  defp trace_note(marker, text, color) do
    %{
      class: "pl-2 w-full overflow-hidden #{color}",
      text: "#{marker} #{text}",
      diff_lines: [],
      diff_truncated?: false
    }
  end

  defp drop_hidden_notes(rows, 0), do: rows

  defp drop_hidden_notes(rows, overflow) do
    {rows, _remaining} =
      Enum.map_reduce(rows, overflow, fn
        %{kind: :note}, remaining when remaining > 0 -> {nil, remaining - 1}
        row, remaining -> {row, remaining}
      end)

    Enum.reject(rows, &is_nil/1)
  end

  defp note_overflow(%{execution_rows: rows, hidden_trace_note_count: hidden_count}),
    do: hidden_count + visible_note_overflow(rows)

  defp visible_note_overflow(rows),
    do: max(Enum.count(rows, &match?(%{kind: :note}, &1)) - @max_visible_notes, 0)

  defp body_section_class(%{role: :user}, _height), do: ""
  defp body_section_class(_item, height) when height >= 32, do: "pt-1"

  defp body_section_class(item, _height) do
    if item.execution_rows != [], do: "pt-1", else: ""
  end

  defp show_placeholder?(item) do
    item.body == "" and active_message?(item) and not active_trace?(item)
  end

  defp active_trace?(item) do
    Enum.any?(item.execution_rows, &(Map.get(&1, :active?, false) == true))
  end

  defp active_message?(%{activity: %Activity.Item{active?: true}}), do: true
  defp active_message?(%{status: status}), do: status in [:queued, :streaming]

  defp split_lines(spans) do
    {lines, current} = Enum.reduce(spans, {[], []}, &split_span/2)
    Enum.reverse([Enum.reverse(current) | lines])
  end

  defp split_span(span, {lines, current}) do
    span.text
    |> String.split("\n", trim: false)
    |> add_span_parts(span, lines, current)
  end

  defp add_span_parts([part], span, lines, current),
    do: {lines, [%{span | text: part} | current]}

  defp add_span_parts([part | rest], span, lines, current) do
    line = Enum.reverse([%{span | text: part} | current])
    add_span_parts(rest, span, [line | lines], [])
  end

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M")
      _ -> ""
    end
  end

  defp error_message(nil), do: nil
  defp error_message(%Failure{message: message}), do: message
  defp error_message(error) when is_map(error), do: error["message"] || error[:message]
  defp error_message(error), do: to_string(error)

  defp error_summary(error, width) do
    error
    |> error_message()
    |> to_string()
    |> String.split(~r/\R/, trim: true)
    |> List.first()
    |> Kernel.||("Provider invocation failed")
    |> humanize_milliseconds()
    |> truncate(max(width - 11, 24))
  end

  defp humanize_milliseconds(message) do
    Regex.replace(~r/\b(\d+)ms\b/, message, fn _, milliseconds ->
      milliseconds |> String.to_integer() |> duration_label()
    end)
  end

  defp duration_label(milliseconds) when rem(milliseconds, 60_000) == 0 do
    minutes = div(milliseconds, 60_000)
    "#{minutes} #{if minutes == 1, do: "minute", else: "minutes"}"
  end

  defp duration_label(milliseconds) when rem(milliseconds, 1_000) == 0 do
    seconds = div(milliseconds, 1_000)
    "#{seconds} #{if seconds == 1, do: "second", else: "seconds"}"
  end

  defp duration_label(milliseconds), do: "#{milliseconds} ms"

  defp truncate(value, limit) do
    if String.length(value) <= limit do
      value
    else
      String.slice(value, 0, limit - 1) <> "…"
    end
  end
end
