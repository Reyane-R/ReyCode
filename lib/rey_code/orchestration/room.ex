defmodule ReyCode.Orchestration.Room do
  @moduledoc "A durable workspace-rooted conversation in the orchestration projection."

  alias ReyCode.Orchestration.Participant
  alias ReyCode.Orchestration.Squad.Seat

  @fields [
    :id,
    :slug,
    :title,
    :workspace,
    :participants,
    :squad_seats,
    :message_order,
    :context_boundary_sequence,
    :context_summary,
    :context_compacted_at,
    :parent_room_id,
    :forked_from_sequence,
    :active_turn_id,
    :queued_turn_ids,
    :created_at
  ]

  defstruct id: nil,
            slug: nil,
            title: nil,
            workspace: nil,
            participants: [],
            squad_seats: %{},
            context_boundary_sequence: 0,
            context_summary: nil,
            context_compacted_at: nil,
            parent_room_id: nil,
            forked_from_sequence: nil,
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
          squad_seats: %{optional(String.t()) => Seat.t()},
          context_boundary_sequence: non_neg_integer(),
          context_summary: String.t() | nil,
          context_compacted_at: term(),
          parent_room_id: String.t() | nil,
          forked_from_sequence: non_neg_integer() | nil,
          message_order: [String.t()],
          active_turn_id: String.t() | nil,
          queued_turn_ids: [String.t()],
          created_at: term()
        }

  @doc "Converts a decoded or legacy room map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(room) when is_map(room) do
    room = Map.put_new(room, :squad_seats, Map.get(room, :squad_roles, %{}))
    room = struct!(__MODULE__, Map.take(room, @fields))

    %{
      room
      | participants: Enum.map(room.participants || [], &Participant.from_map/1),
        squad_seats:
          Map.new(room.squad_seats || %{}, fn {id, seat} ->
            {id, Seat.from_map(seat)}
          end)
    }
  end
end
