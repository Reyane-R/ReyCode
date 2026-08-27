defmodule ReyCode.TUI.Workspace do
  @moduledoc """
  State, input handling, and rendering for the workspace-path modal.
  """

  use Breeze.Component

  alias Breeze.{Component, View}

  @doc "Opens the current session's workspace path."
  @spec open(map(), String.t() | nil) :: map()
  def open(term, relative_path \\ nil) do
    projection = Map.get(term.assigns, :projection)
    room_id = Map.get(term.assigns, :selected_room_id)
    room = projection && Map.get(projection.rooms, room_id)
    workspace = room && Map.get(room, :workspace)

    path =
      if relative_path && workspace,
        do: Path.join(workspace, relative_path),
        else: workspace

    Component.assign(term,
      modal: :workspace,
      slash: nil,
      workspace_preview_path: path,
      notice: nil
    )
  end

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

  @doc "Renders the session's absolute workspace path."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Workspace</box>
        <box class="text-muted">The Assistant and task agents run in this directory.</box>
      </box>
      <box class="pt-3 text-muted">WORKSPACE PATH</box>
      <box class="pt-1 w-full">
        {wrap_workspace(@term.workspace_preview_path, @term.breeze.terminal.width - 8)}
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
