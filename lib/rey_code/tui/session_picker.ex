defmodule ReyCode.TUI.SessionPicker do
  @moduledoc "Owns resuming one previous durable session from a selectable list."

  use Breeze.Component
  alias Breeze.{Component, View}
  alias ReyCode.TUI.{SlashPalette, State, TimeAgo}

  @spec initial() :: map()
  def initial, do: %{index: 0}

  @spec open(map()) :: map()
  def open(term) do
    case sessions(term) do
      [] ->
        SlashPalette.close(term, "No previous sessions yet")

      _sessions ->
        term
        |> Component.assign(
          modal: :session_picker,
          session_picker: initial(),
          slash: nil,
          notice: nil
        )
        |> View.focus("prompt")
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(sessions(term))
    index = Integer.mod(term.assigns.session_picker.index + offset, count)
    {:noreply, Component.assign(term, session_picker: %{index: index})}
  end

  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    session = Enum.at(sessions(term), term.assigns.session_picker.index)

    next =
      term
      |> Component.assign(
        modal: nil,
        session_picker: initial(),
        notice: nil
      )
      |> State.select_session(session.id)
      |> View.focus("prompt")

    {:noreply, next}
  end

  defp cancel(term) do
    term
    |> Component.assign(modal: nil, session_picker: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp sessions(term) do
    assigns = term_assigns(term)

    assigns.projection.session_order
    |> Enum.reverse()
    |> Enum.map(&assigns.projection.sessions[&1])
    |> Enum.filter(&(&1.message_order != []))
  end

  defp term_assigns(%{assigns: assigns}), do: assigns
  defp term_assigns(assigns), do: assigns

  attr :term, :map, required: true

  @doc "Renders the previous-session list."
  def modal(assigns) do
    assigns = Component.assign(assigns, selected: assigns_index(Map.get(assigns, :term, assigns)))

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Resume a session</box>
        <box class="text-muted">Pick one previous session to reopen.</box>
      </box>
      <box class="pt-3 w-full">
        <box
          :for={{session, index} <- Enum.with_index(picker_sessions(@term))}
          class={row_class(index, @selected)}
        >
          {marker(index, @selected)} {session.title}  ·  {TimeAgo.format(session.created_at)}  ·  {Path.basename(session.workspace)}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter resume   Esc cancel</box>
    </box>
    """
  end

  defp picker_sessions(term), do: sessions(term)

  defp assigns_index(term) do
    case term do
      %{assigns: %{session_picker: %{index: index}}} -> index
      %{session_picker: %{index: index}} -> index
      _other -> 0
    end
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
