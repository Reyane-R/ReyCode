defmodule ReyCode.TUI.NewRoom do
  @moduledoc """
  State, input handling, and rendering for the new-room modal.
  """

  use Breeze.Component

  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine

  @doc "Handles one key press while the new-room modal is active."
  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @doc "Handles the modal's textarea change and submit events."
  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("new_room_changed", %{value: value}, term) do
    {:noreply, change(term, value)}
  end

  def handle_event("new_room_submitted", %{value: value}, term), do: submit_value(term, value)
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns empty new-room form state rooted at the current workspace."
  @spec initial() :: map()
  def initial, do: %{name: "", workspace: File.cwd!()}

  @doc "Opens the new-room modal and focuses its name field."
  @spec open(map()) :: map()
  def open(term) do
    term
    |> Component.assign(modal: :new_room, new_room: initial())
    |> View.focus("new-room-name")
  end

  @doc "Keeps focus on the modal's only input."
  @spec focus(map()) :: map()
  def focus(term), do: View.focus(term, "new-room-name")

  @doc "Updates the room name without changing the form shape."
  @spec change(map(), String.t()) :: map()
  def change(term, value) do
    Component.assign(term, new_room: %{term.assigns.new_room | name: value})
  end

  @doc "Submits a room name received directly from the textarea event."
  @spec submit_value(map(), String.t()) :: {:noreply, map()}
  def submit_value(term, value), do: term |> change(value) |> submit()

  @doc "Creates the room and closes the modal on success."
  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    case Engine.create_room(
           term.assigns.new_room.name,
           term.assigns.new_room.workspace,
           term.assigns.engine
         ) do
      {:ok, room_id} ->
        {:noreply,
         term
         |> Component.assign(
           selected_room_id: room_id,
           modal: nil,
           new_room: initial(),
           notice: nil
         )
         |> View.focus("prompt")}

      {:error, :empty_title} ->
        {:noreply, Component.assign(term, notice: "Room name is required")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not create room: #{reason}")}
    end
  end

  @doc "Cancels room creation and restores prompt focus."
  @spec cancel(map()) :: map()
  def cancel(term) do
    term
    |> Component.assign(modal: nil, new_room: initial())
    |> View.focus("prompt")
  end

  attr :term, :map, required: true

  @doc "Renders the new-room modal."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Create a project room</box>
        <box class="text-muted">Rooms keep project context, messages, and agent work together.</box>
      </box>
      <box class="pt-3 text-muted">ROOM NAME</box>
      <box class="w-full pt-1">
        <.textarea
          id="new-room-name"
          textarea-value={@term.new_room.name}
          textarea-placeholder="Payments rewrite"
          textarea-submit-on-enter={true}
          br-change="new_room_changed"
          br-submit="new_room_submitted"
          class="w-full h-3"
        />
      </box>
      <box class="pt-2 text-muted">WORKSPACE</box>
      <box class="w-full overflow-hidden">{@term.new_room.workspace}</box>
      <box class="pt-2 text-muted">Enter create   Esc cancel</box>
    </box>
    """
  end
end
