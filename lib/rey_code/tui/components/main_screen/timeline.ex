defmodule ReyCode.TUI.Components.MainScreen.Timeline do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  alias ReyCode.Failure
  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.{Activity, MermaidASCII}

  @max_visible_notes 3

  attr :messages, :list, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :activity_frame, :string, required: true

  def timeline(assigns) do
    ~H"""
    <.scroll
      id={@timeline_id}
      scroll-autoscroll="bottom"
      class="h-full w-full border-none overflow-scroll mute-scrollbar-40 px-2 py-1"
    >
      <box :if={@messages == []} class="pt-4 w-full">
        <box class="font-bold text-primary">TIMELINE / STANDBY</box>
        <box class="pt-1 text-muted">Send a message to the Assistant or delegate with /task.</box>
      </box>
      <box :for={item <- @messages} class="w-full">
        <box :if={item.kind == :context_boundary} class="w-full py-1 text-warning">
          EVENT / CONTEXT COMPACTED / SEQ {item.created_sequence} / /context inspect
          <box class="pl-2 text-muted">│ {boundary_preview(item.summary)}</box>
        </box>
        <box :if={item.kind == :message} class={message_class(item)}>
          <box class="inline w-full overflow-hidden">
            <box class={author_name_class(item)}>{author_role(item)} / {item.author.name}</box>
            <box :if={message_metadata(item) != ""} class="text-muted">{metadata_label(item)}</box>
            <box class={message_status_class(item)}>{message_status(item)}</box>
          </box>
          <box
            :for={line <- if item.body != "" do
      render_message(item, @message_width)
    else
      []
    end}
            class="inline pl-2 w-full overflow-hidden"
          >
            <box class="text-muted">│ </box>
            <box>{line}</box>
          </box>
          <box
            :if={item.body == "" and item.status in [:queued, :streaming]}
            class="pl-2 w-full text-muted"
          >
            │ {message_placeholder(item, @activity_frame)}
          </box>
          <box :if={item.error} class="pl-2 w-full overflow-hidden text-error">
            └ FAULT / {error_summary(item.error, @message_width)}
          </box>
          <box :if={note_overflow(item) > 0} class="pl-2 w-full text-muted">
            │ +{note_overflow(item)} more activity
          </box>
          <box :for={row <- visible_notes(item)} class="pl-2 w-full overflow-hidden text-muted">
            │ NOTE / {row}
          </box>
          <box :for={row <- item.tool_run_rows} class="w-full">
            <box class={tool_row_class(row)}>├ TOOL / {Activity.text(row, @activity_frame)}</box>
            <box :for={line <- row.diff_lines} class={diff_line_class(line)}>│   {line}</box>
            <box :if={row.diff_truncated?} class="pl-4 w-full text-muted">
              │   … diff preview truncated / /runs inspect arguments
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
    message.body
    |> MermaidASCII.expand()
    |> Breeze.Markdown.render(width)
    |> split_lines()
  end

  defp message_placeholder(%{activity: nil, status: :queued}, _frame), do: "Waiting…"
  defp message_placeholder(%{activity: nil}, frame), do: frame <> " · Thinking"
  defp message_placeholder(%{activity: activity}, frame), do: Activity.text(activity, frame)

  defp message_metadata(%{role: :user, created_at: created_at, turn: %{mode: :delegate}}) do
    [timestamp(created_at), "task"] |> Enum.reject(&(&1 == "")) |> Enum.join("  ·  ")
  end

  defp message_metadata(%{role: :user, created_at: created_at}), do: timestamp(created_at)

  defp message_metadata(%{invocation: invocation}) when not is_nil(invocation) do
    Presentation.short_runtime_label(invocation.participant)
  end

  defp message_metadata(_message), do: ""

  defp metadata_label(message), do: "  ·  " <> message_metadata(message)

  defp author_role(%{role: :user}), do: "OPERATOR"
  defp author_role(_message), do: "PARTICIPANT"

  defp message_class(%{role: :user}), do: "w-full pt-1 overflow-hidden"
  defp message_class(_message), do: "w-full overflow-hidden"

  defp author_name_class(%{role: :user}), do: "font-bold text-secondary"
  defp author_name_class(%{author: %{id: "builder"}}), do: "font-bold text-primary"
  defp author_name_class(%{author: %{id: "critic"}}), do: "font-bold text-warning"
  defp author_name_class(_message), do: "font-bold text-primary"

  defp message_status(%{activity: activity}), do: activity |> Activity.badge() |> String.upcase()

  defp message_status_class(%{activity: activity}) do
    "w-full text-right text-#{Activity.color(activity)}"
  end

  defp tool_row_class(row), do: "pl-2 w-full overflow-hidden text-#{Activity.color(row)}"
  defp diff_line_class("+" <> _line), do: "pl-4 w-full text-success"
  defp diff_line_class("-" <> _line), do: "pl-4 w-full text-error"
  defp diff_line_class("@@" <> _line), do: "pl-4 w-full text-secondary"
  defp diff_line_class(_line), do: "pl-4 w-full text-muted"

  defp visible_notes(%{note_rows: notes}) when is_list(notes),
    do: Enum.take(notes, -@max_visible_notes)

  defp note_overflow(%{note_rows: notes}) when is_list(notes),
    do: max(length(notes) - @max_visible_notes, 0)

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
