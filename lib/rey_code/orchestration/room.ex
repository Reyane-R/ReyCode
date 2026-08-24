defmodule ReyCode.Orchestration.Room do
  @moduledoc "A durable room in the orchestration projection."

  alias ReyCode.Orchestration.Participant

  @fields [
    :id,
    :slug,
    :title,
    :workspace,
    :participants,
    :squad_roles,
    :message_order,
    :active_turn_id,
    :queued_turn_ids,
    :created_at
  ]

  defstruct id: nil,
            slug: nil,
            title: nil,
            workspace: nil,
            participants: [],
            squad_roles: %{},
            message_order: [],
            active_turn_id: nil,
            queued_turn_ids: [],
            created_at: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          slug: String.t() | nil,
          title: String.t() | nil,
          workspace: String.t() | nil,
          participants: [Participant.t()],
          squad_roles: %{optional(String.t()) => Participant.t()},
          message_order: [String.t()],
          active_turn_id: String.t() | nil,
          queued_turn_ids: [String.t()],
          created_at: term()
        }

  @doc "Converts a decoded or legacy room map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(room) when is_map(room) do
    room = struct!(__MODULE__, Map.take(room, @fields))

    %{
      room
      | participants: Enum.map(room.participants || [], &Participant.from_map/1),
        squad_roles:
          Map.new(room.squad_roles || %{}, fn {id, participant} ->
            {id, Participant.from_map(participant)}
          end)
    }
  end
end
