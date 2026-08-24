defmodule ReyCode.TUI.Components.MainScreen.RoomPresentation do
  @moduledoc false

  alias ReyCode.Orchestration.Squad

  def visible_participants(room, :squad) do
    configured = Map.get(room, :squad_roles, %{})

    Enum.map(Squad.roles(), fn role ->
      Map.get(configured, role.id, %{
        id: role.id,
        name: role.name,
        perspective: role.perspective,
        provider: :unconfigured,
        model: nil
      })
    end)
  end

  def visible_participants(room, _mode), do: room.participants

  def participant_section_label(:squad), do: "SQUAD ROLES"
  def participant_section_label(_mode), do: "AGENTS IN ROOM"

  def room_label(room), do: "##{room.slug}"

  def mode_label(:fan_out), do: "fan-out"
  def mode_label(mode), do: Atom.to_string(mode)
end
