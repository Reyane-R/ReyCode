defmodule ReyCode.TUI.Components.MainScreen.Sidebar do
  @moduledoc false

  use Breeze.Component

  import ReyCode.TUI.Components.MainScreen.RoomPresentation,
    only: [participant_section_label: 1, visible_participants: 2]

  alias ReyCode.Provider.Presentation

  attr :show_sidebar, :boolean, required: true
  attr :rooms, :list, required: true
  attr :selected_room_id, :string, required: true
  attr :mode, :atom, required: true
  attr :room, :map, required: true
  attr :projection, :map, required: true
  attr :providers, :map, required: true

  def sidebar(assigns) do
    ~H"""
    <box
      :if={@show_sidebar}
      class="h-full w-30 bg-surface border-r border-muted px-2 pt-1 overflow-hidden"
    >
      <box class="h-4 w-full">
        <box class="font-bold text-primary">REYCODE</box>
        <box class="text-muted">project rooms</box>
      </box>
      <box class="inline pt-1 w-full overflow-hidden">
        <box class="text-muted">ROOMS</box>
        <box class="w-full text-right text-muted">Ctrl+N new</box>
      </box>
      <box id="rooms" focusable class="w-full overflow-hidden pt-1">
        <box :for={item <- @rooms} class={room_class(item.id, @selected_room_id)}>#  {item.slug}</box>
      </box>
      <box class="pt-2 text-muted">{participant_section_label(@mode)}</box>
      <box
        :for={participant <- visible_participants(@room, @mode)}
        class={presence_class(participant, @room, @projection, @providers) <> " w-full overflow-hidden"}
      >
        o  {participant.name}  {Presentation.short_runtime_label(participant)}
      </box>
      <box class="pt-2 px-1 text-muted w-full overflow-hidden">
        o  event log  {@projection.sequence}
      </box>
      <box class="px-1 text-muted w-full overflow-hidden">{Path.basename(@room.workspace)}</box>
    </box>
    """
  end

  defp room_class(room_id, room_id), do: "w-full px-1 bg-panel font-bold text-primary"
  defp room_class(_room_id, _selected_room_id), do: "w-full px-1 text-muted"

  defp presence_class(participant, room, projection, providers) do
    invocation =
      if room.active_turn_id do
        turn = projection.turns[room.active_turn_id]

        turn.invocation_order
        |> Enum.map(&projection.invocations[&1])
        |> Enum.reverse()
        |> Enum.find(&(&1.participant.id == participant.id))
      end

    case invocation && invocation.status do
      status when status in [:queued, :running] -> "px-1 text-warning"
      :failed -> "px-1 text-error"
      _ -> Presentation.text_class(providers[participant.provider], participant)
    end
  end
end
