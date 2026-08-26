defmodule ReyCode.TUI.Components.MainScreen.Timeline do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  alias ReyCode.Failure
  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.Spinner

  @compile {:no_warn_undefined, ReyCode.TUI.Spinner}

  @max_visible_notes 3

  attr :messages, :list, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true

  def timeline(assigns) do
    ~H"""
    <.scroll
      id={@timeline_id}
      scroll-autoscroll="bottom"
      class="h-full w-full border-none overflow-scroll mute-scrollbar-40 px-2 py-1"
    >
      <box :if={@messages == []} class="pt-4 w-full">
        <box class="font-bold text-primary">Start a conversation</box>
        <box class="pt-1 text-muted">Send a message to the Assistant or delegate with /task.</box>
      </box>
      <box :for={message <- @messages} class={message_class(message)}>
        <box class="inline w-full overflow-hidden">
          <box class={author_name_class(message)}>{message.author.name}</box>
          <box :if={message_metadata(message) != ""} class="text-muted">
            {metadata_label(message)}
          </box>
          <box class={message_status_class(message.status)}>{message_status(message.status)}</box>
        </box>
        <box :if={message.body != ""} class="pl-2 w-full overflow-hidden">
          <box :for={line <- render_message(message, @message_width)} class="w-full">{line}</box>
        </box>
        <box
          :if={message.body == "" and message.status in [:queued, :streaming]}
          class="pl-2 w-full text-muted"
        >
          {message_placeholder(message.status)}
        </box>
        <box :if={message.error} class="pl-2 w-full overflow-hidden text-error">
          Failed · {error_summary(message.error, @message_width)}
        </box>
        <box :if={note_overflow(message) > 0} class="pl-2 w-full text-muted">
          +{note_overflow(message)} more activity
        </box>
        <box :for={row <- visible_notes(message)} class="pl-2 w-full overflow-hidden text-muted">
          · {row}
        </box>
        <box :for={row <- message.tool_run_rows} class="pl-2 w-full overflow-hidden text-muted">
          Tool · {row.tool}  {row.target}  {tool_run_status(row)}
        </box>
      </box>
    </.scroll>
    """
  end

  defp render_message(message, width) do
    message.body
    |> Breeze.Markdown.render(width)
    |> split_lines()
  end

  defp message_placeholder(:queued), do: "Waiting…"
  defp message_placeholder(:streaming), do: Spinner.glyph() <> " Thinking…"

  defp message_metadata(%{role: :user, created_at: created_at, turn: %{mode: :delegate}}) do
    [timestamp(created_at), "task"] |> Enum.reject(&(&1 == "")) |> Enum.join("  ·  ")
  end

  defp message_metadata(%{role: :user, created_at: created_at}), do: timestamp(created_at)

  defp message_metadata(%{invocation: invocation}) when not is_nil(invocation) do
    Presentation.short_runtime_label(invocation.participant)
  end

  defp message_metadata(_message), do: ""

  defp metadata_label(message), do: "  ·  " <> message_metadata(message)

  defp message_class(%{role: :user}), do: "w-full pt-1 overflow-hidden"
  defp message_class(_message), do: "w-full overflow-hidden"

  defp author_name_class(%{role: :user}), do: "font-bold text-secondary"
  defp author_name_class(%{author: %{id: "builder"}}), do: "font-bold text-primary"
  defp author_name_class(%{author: %{id: "critic"}}), do: "font-bold text-warning"
  defp author_name_class(_message), do: "font-bold text-primary"

  defp message_status(:queued), do: "waiting"
  defp message_status(:streaming), do: "thinking"
  defp message_status(_status), do: ""

  defp message_status_class(status) when status in [:queued, :streaming],
    do: "w-full text-right text-warning"

  defp message_status_class(_status), do: "w-full text-right text-muted"

  defp tool_run_status(%{status: status}) when status in ["running", "awaiting approval"],
    do: Spinner.glyph() <> " " <> status

  defp tool_run_status(row), do: row.status

  defp visible_notes(%{note_rows: notes}) when is_list(notes),
    do: Enum.take(notes, -@max_visible_notes)

  defp visible_notes(_message), do: []

  defp note_overflow(%{note_rows: notes}) when is_list(notes),
    do: max(length(notes) - @max_visible_notes, 0)

  defp note_overflow(_message), do: 0

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
