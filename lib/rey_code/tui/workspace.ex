defmodule ReyCode.TUI.Workspace do
  @moduledoc """
  State, input handling, and rendering for the workspace-path modal.
  """

  use Breeze.Component

  alias Breeze.{Component, View}

  @doc "Opens the selected room's workspace path."
  @spec open(map()) :: map()
  def open(term), do: Component.assign(term, modal: :workspace, slash: nil, notice: nil)

  @doc "Keeps global focus unchanged while the modal is open."
  @spec focus(map()) :: map()
  def focus(term), do: term

  @doc "Submits nothing; the workspace modal is informational."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, term}

  @doc "Handles one key press while the workspace modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles component events; the workspace modal declares none."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Closes the workspace path and restores prompt focus."
  @spec close(map()) :: map()
  def close(term), do: term |> Component.assign(modal: nil) |> View.focus("prompt")

  attr :term, :map, required: true

  @doc "Renders the room's absolute workspace path."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Room workspace</box>
        <box class="text-muted">OpenCode runs with this exact working directory.</box>
      </box>
      <box class="pt-3 text-muted">ABSOLUTE PATH</box>
      <box class="pt-1 w-full">
        {wrap_workspace(@term.room.workspace, @term.breeze.terminal.width - 8)}
      </box>
      <box class="pt-3 text-muted">Esc close</box>
    </box>
    """
  end

  defp wrap_workspace(path, width) do
    path
    |> String.graphemes()
    |> Enum.chunk_every(max(width, 20))
    |> Enum.map_join("\n", &Enum.join/1)
  end
end
