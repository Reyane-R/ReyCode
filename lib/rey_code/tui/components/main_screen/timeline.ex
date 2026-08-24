defmodule ReyCode.TUI.Components.MainScreen.Timeline do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  import ReyCode.TUI.Components.MainScreen.RoomPresentation,
    only: [mode_label: 1, room_label: 1]

  alias ReyCode.Failure
  alias ReyCode.Provider.Presentation

  attr :messages, :list, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :room, :map, required: true

  def timeline(assigns) do
    ~H"""
    <.scroll
      id={@timeline_id}
      scroll-autoscroll="bottom"
      class="h-full w-full border-none overflow-scroll mute-scrollbar-40 px-2 py-1"
    >
      <box :if={@messages == []} class="pt-4 w-full">
        <box class="font-bold text-primary">Welcome to {room_label(@room)}</box>
        <box class="pt-1 text-muted">
          Send a message, choose an orchestration mode, and let the room respond.
        </box>
      </box>
      <box :for={message <- @messages} class="w-full pb-1 overflow-hidden">
        <box class="inline w-full overflow-hidden">
          <box class={author_badge_class(message)}>{author_badge(message)}</box>
          <box class="font-bold">{message.author.name}</box>
          <box class={message_status_class(message.status)}>{message_status(message.status)}</box>
        </box>
        <box :if={message_metadata(message) != ""} class="pl-3 w-full overflow-hidden text-muted">
          {message_metadata(message)}
        </box>
        <box :if={message.body != ""} class="pl-3 w-full overflow-hidden">
          {render_message(message, @message_width)}
        </box>
        <box
          :if={message.body == "" and message.status in [:queued, :streaming]}
          class="pl-3 w-full text-muted"
        >
          {message_placeholder(message.status)}
        </box>
        <box :if={message.error} class="pl-3 w-full overflow-hidden text-error">
          {error_summary(message.error)}
        </box>
      </box>
    </.scroll>
    """
  end

  defp render_message(message, width), do: Breeze.Markdown.render(message.body, width)

  defp message_placeholder(:queued), do: "queued"
  defp message_placeholder(:streaming), do: "thinking..."

  defp message_metadata(%{role: :user, created_at: created_at, turn: turn}) do
    [timestamp(created_at), mode_label(turn.mode)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("  /  ")
  end

  defp message_metadata(%{invocation: invocation}) when not is_nil(invocation) do
    [invocation.label, Presentation.short_runtime_label(invocation.participant)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("  /  ")
  end

  defp message_metadata(_message), do: ""

  defp author_badge(%{role: :user}), do: "[Y]"
  defp author_badge(%{author: %{id: "builder"}}), do: "[B]"
  defp author_badge(%{author: %{id: "critic"}}), do: "[C]"
  defp author_badge(%{author: %{id: "explorer"}}), do: "[E]"
  defp author_badge(_message), do: "[A]"

  defp author_badge_class(%{role: :user}), do: "w-3 font-bold text-secondary"
  defp author_badge_class(%{author: %{id: "builder"}}), do: "w-3 font-bold text-primary"
  defp author_badge_class(%{author: %{id: "critic"}}), do: "w-3 font-bold text-warning"
  defp author_badge_class(_message), do: "w-3 font-bold text-secondary"

  defp message_status(:queued), do: "queued"
  defp message_status(:streaming), do: "typing"
  defp message_status(:failed), do: "failed"
  defp message_status(_status), do: ""

  defp message_status_class(:failed), do: "w-full text-right text-error"

  defp message_status_class(status) when status in [:queued, :streaming],
    do: "w-full text-right text-warning"

  defp message_status_class(_status), do: "w-full text-right text-muted"

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

  defp error_summary(error) do
    error
    |> error_message()
    |> to_string()
    |> String.split(~r/\R/, trim: true)
    |> List.first()
    |> Kernel.||("Provider invocation failed")
    |> humanize_milliseconds()
    |> truncate(180)
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
