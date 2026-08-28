defmodule ReyCode.TUI.Hotkeys do
  @moduledoc "Read-only reference for effective configurable keybindings."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.TUI.SlashPalette

  @spec initial() :: map()
  def initial, do: %{offset: 0}

  @spec open(map()) :: map()
  def open(term) do
    term
    |> SlashPalette.clear()
    |> Component.assign(modal: :hotkeys, hotkeys: initial(), notice: nil)
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, close(term)}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    delta = if key in ["ArrowUp", "k"], do: -1, else: 1
    maximum = max(length(term.assigns.keybindings.entries) - 1, 0)
    offset = (term.assigns.hotkeys.offset + delta) |> max(0) |> min(maximum)
    {:noreply, Component.assign(term, hotkeys: %{offset: offset})}
  end

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input("Enter", term), do: submit(term)
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    entries = Enum.slice(assigns.term.keybindings.entries, assigns.term.hotkeys.offset, 22)
    assigns = Map.put(assigns, :entries, entries)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-secondary pb-1">
        <box class="font-bold text-secondary">Hotkeys</box>
        <box class="text-muted">Effective action bindings · {@term.keybindings.path}</box>
      </box>
      <box class="pt-2 w-full">
        <box :for={entry <- @entries} class="inline w-full">
          <box class="w-24 font-bold text-primary">{chord_label(entry.chords)}</box>
          <box class="w-30 text-muted">{entry.id}</box>
          <box>{entry.label}</box>
        </box>
      </box>
      <box :for={error <- @term.keybindings.errors} class="pt-1 text-warning">{error}</box>
      <box class="pt-2 text-muted">j/k scroll   Enter or Esc close</box>
    </box>
    """
  end

  defp close(term),
    do:
      term
      |> Component.assign(modal: nil, hotkeys: initial(), notice: nil)
      |> View.focus("prompt")

  defp chord_label([]), do: "unbound"
  defp chord_label(chords), do: Enum.join(chords, ", ")
end
