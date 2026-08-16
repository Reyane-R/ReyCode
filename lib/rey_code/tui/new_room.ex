defmodule ReyCode.TUI.NewRoom do
  @moduledoc "State transitions for the new-room modal."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine

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
end
