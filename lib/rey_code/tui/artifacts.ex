defmodule ReyCode.TUI.Artifacts do
  @moduledoc "Bounded list and pager for spooled ToolRun artifacts."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.ArtifactStore
  alias ReyCode.TUI.SlashPalette

  @visible_line_count 24

  @spec initial() :: map()
  def initial, do: %{step: :list, index: 0, artifact_id: nil, offset: 0, bytes: "", metadata: %{}}

  @spec open(map()) :: map()
  def open(term) do
    artifacts = ArtifactStore.list(term.assigns.config.artifacts)

    if artifacts == [] do
      SlashPalette.close(term, "No spooled artifacts")
    else
      term
      |> SlashPalette.clear()
      |> Component.assign(modal: :artifacts, artifacts: initial(), notice: nil)
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, open_selected(term)}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, %{assigns: %{artifacts: %{step: :list}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(ArtifactStore.list(term.assigns.config.artifacts))
    index = Integer.mod(term.assigns.artifacts.index + offset, count)
    {:noreply, Component.assign(term, artifacts: %{term.assigns.artifacts | index: index})}
  end

  def handle_input("Enter", %{assigns: %{artifacts: %{step: :list}}} = term),
    do: {:noreply, open_selected(term)}

  def handle_input(key, %{assigns: %{artifacts: %{step: :detail}}} = term)
      when key in ["ArrowDown", "j"] do
    {:noreply,
     read_window(
       term,
       term.assigns.artifacts.offset + term.assigns.config.artifacts.preview_bytes
     )}
  end

  def handle_input(key, %{assigns: %{artifacts: %{step: :detail}}} = term)
      when key in ["ArrowUp", "k"] do
    offset = max(term.assigns.artifacts.offset - term.assigns.config.artifacts.preview_bytes, 0)
    {:noreply, read_window(term, offset)}
  end

  def handle_input("Escape", %{assigns: %{artifacts: %{step: :detail}}} = term),
    do: {:noreply, Component.assign(term, artifacts: initial(), notice: nil)}

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    items = ArtifactStore.list(assigns.term.config.artifacts)
    assigns = Map.put(assigns, :artifact_items, items)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-secondary pb-1">
        <box class="font-bold text-secondary">Artifacts</box>
        <box class="text-muted">Bounded ToolRun output spool</box>
      </box>
      <box :if={@term.artifacts.step == :list} class="pt-3 w-full">
        <box
          :for={{artifact, index} <- Enum.with_index(@artifact_items)}
          class={row_class(index, @term.artifacts.index)}
        >
          {marker(index, @term.artifacts.index)} artifact://{artifact.id} · {artifact.bytes} bytes
        </box>
      </box>
      <box :if={@term.artifacts.step == :detail} class="pt-2 w-full">
        <box class="font-bold">artifact://{@term.artifacts.artifact_id}</box>
        <box class="text-muted">bytes {@term.artifacts.offset}–{window_end(@term.artifacts)}</box>
        <box class="pt-1 w-full bg-panel overflow-hidden">
          <box :for={line <- artifact_lines(@term.artifacts.bytes)}>{line}</box>
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">{controls(@term.artifacts.step)}</box>
    </box>
    """
  end

  defp open_selected(term) do
    artifact =
      Enum.at(ArtifactStore.list(term.assigns.config.artifacts), term.assigns.artifacts.index)

    state = %{term.assigns.artifacts | step: :detail, artifact_id: artifact.id, offset: 0}
    term |> Component.assign(artifacts: state) |> read_window(0)
  end

  defp read_window(term, offset) do
    state = term.assigns.artifacts

    case ArtifactStore.read(
           term.assigns.config.artifacts,
           state.artifact_id,
           offset,
           term.assigns.config.artifacts.preview_bytes
         ) do
      {:ok, bytes, metadata} ->
        Component.assign(term,
          artifacts: %{state | offset: offset, bytes: bytes, metadata: metadata},
          notice: nil
        )

      {:error, reason} ->
        Component.assign(term, notice: "Could not read artifact: #{reason}")
    end
  end

  defp close(term) do
    term
    |> Component.assign(modal: nil, artifacts: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp artifact_lines(bytes),
    do: bytes |> String.split("\n", trim: false) |> Enum.take(@visible_line_count)

  defp window_end(state), do: state.offset + byte_size(state.bytes)
  defp controls(:list), do: "Arrow keys or j/k move   Enter open   Esc close"
  defp controls(:detail), do: "j/k page bytes   Esc list"
  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-secondary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
