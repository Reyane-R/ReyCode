defmodule ReyCode.TUI.ContextBoundary do
  @moduledoc "Read-only inspection of the selected Session's latest ContextBoundary."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.TUI.SlashPalette

  @max_summary_bytes 65_536
  @visible_line_count 24

  @spec initial() :: map()
  def initial, do: %{offset: 0}

  @spec open(map()) :: map()
  def open(term) do
    case selected_session(term) do
      %{context_boundary_sequence: sequence} when sequence > 0 ->
        term
        |> SlashPalette.clear()
        |> Component.assign(modal: :context_boundary, context_boundary: initial(), notice: nil)

      _session ->
        SlashPalette.close(term, "This Session has no ContextBoundary")
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, close(term)}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term)
      when key in ["ArrowUp", "ArrowDown", "j", "k", "PageUp", "PageDown"] do
    delta = scroll_delta(key)
    maximum = max(length(summary_lines(term)) - @visible_line_count, 0)
    offset = (term.assigns.context_boundary.offset + delta) |> max(0) |> min(maximum)
    {:noreply, Component.assign(term, context_boundary: %{offset: offset})}
  end

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input("Enter", term), do: submit(term)
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    session = selected_session(assigns.term)

    lines =
      assigns.term
      |> summary_lines()
      |> Enum.slice(assigns.term.context_boundary.offset, @visible_line_count)

    assigns = assigns |> Map.put(:session, session) |> Map.put(:lines, lines)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-warning pb-1">
        <box class="font-bold text-warning">
          ContextBoundary · sequence {@session.context_boundary_sequence}
        </box>
        <box class="text-muted">
          Provider context changed; durable transcript history remains intact.
        </box>
      </box>
      <box class="pt-2 text-muted">Compacted {@session.context_compacted_at}</box>
      <box class="pt-1 font-bold">Provider-facing summary</box>
      <box :for={line <- @lines} class="text-muted">{line}</box>
      <box class="pt-2 text-muted">j/k or PageUp/PageDown scroll   Enter or Esc close</box>
    </box>
    """
  end

  defp selected_session(%{assigns: assigns}), do: selected_session(assigns)

  defp selected_session(assigns),
    do: Map.get(assigns.projection.sessions, assigns.selected_session_id)

  defp summary_lines(term) do
    summary = selected_session(term).context_summary || "Summary unavailable"

    summary
    |> TextBuffer.truncate_utf8(@max_summary_bytes)
    |> String.split("\n", trim: false)
  end

  defp close(term),
    do:
      term
      |> Component.assign(modal: nil, context_boundary: initial(), notice: nil)
      |> View.focus("prompt")

  defp scroll_delta(key) when key in ["ArrowUp", "k"], do: -1
  defp scroll_delta(key) when key in ["ArrowDown", "j"], do: 1
  defp scroll_delta("PageUp"), do: -@visible_line_count
  defp scroll_delta("PageDown"), do: @visible_line_count
end
