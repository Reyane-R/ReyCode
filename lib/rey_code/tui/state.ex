defmodule ReyCode.TUI.State do
  @moduledoc "Shared terminal state initialization and projection updates for the root view."

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Orchestration.Squad.Dashboard
  alias ReyCode.Provider.{Catalog, Presentation}
  alias ReyCode.TUI.{Directive, GateReview, NewRoom, Settings}

  @doc "Subscribes the root view and initializes its stable assign shapes."
  @spec mount(keyword(), map()) :: {:ok, map()}
  def mount(opts, term) do
    engine = Keyword.get(opts, :engine, Engine)
    provider_catalog = Keyword.get(opts, :provider_catalog, Catalog)
    projection = Engine.subscribe(engine)
    providers = Catalog.subscribe(provider_catalog)

    {:ok,
     term
     |> View.focus("prompt")
     |> Component.assign(
       engine: engine,
       provider_catalog: provider_catalog,
       providers: providers,
       projection: projection,
       selected_room_id: List.first(projection.room_order),
       drafts: %{},
       mode: :compare,
       modal: nil,
       cancel_turn_id: nil,
       directive: Directive.initial(),
       gate_review: GateReview.initial(),
       slash: nil,
       new_room: NewRoom.initial(),
       settings: Settings.initial(),
       notice: nil
     )}
  end

  @doc "Adds transient values consumed by the extracted renderer."
  @spec prepare_render(map()) :: map()
  def prepare_render(assigns) do
    width = assigns.breeze.terminal.width
    sidebar? = show_sidebar?(width)
    room = assigns.projection.rooms[assigns.selected_room_id]

    Component.assign(assigns,
      show_sidebar?: sidebar?,
      room: room,
      rooms: Enum.map(assigns.projection.room_order, &assigns.projection.rooms[&1]),
      messages: room_messages(room, assigns.projection),
      dashboard: Dashboard.data(room, assigns.projection),
      draft: Map.get(assigns.drafts, assigns.selected_room_id, ""),
      message_width: message_width(width, sidebar?),
      timeline_id: timeline_id(room.id),
      gate_review_options: GateReview.options()
    )
  end

  @doc "Updates the projection while retaining a valid room selection."
  @spec projection_updated(map(), map()) :: map()
  def projection_updated(term, projection) do
    selected_room_id =
      if Map.has_key?(projection.rooms, term.assigns.selected_room_id) do
        term.assigns.selected_room_id
      else
        List.first(projection.room_order)
      end

    Component.assign(term, projection: projection, selected_room_id: selected_room_id)
  end

  @doc "Updates provider options and reconciles an open settings wizard."
  @spec providers_updated(map(), map()) :: map()
  def providers_updated(term, providers) do
    notice =
      if term.assigns.notice == Presentation.refresh_notice(), do: nil, else: term.assigns.notice

    term = Component.assign(term, providers: providers, notice: notice)

    if term.assigns.modal == :settings, do: Settings.reconcile_options(term), else: term
  end

  @doc "Updates the selected room's composer draft."
  @spec assign_draft(map(), String.t()) :: map()
  def assign_draft(term, value) do
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_room_id, value)
    Component.assign(term, drafts: drafts)
  end

  @doc "Selects an adjacent room, wrapping in projection order."
  @spec select_adjacent_room(map(), integer()) :: map()
  def select_adjacent_room(term, offset) do
    ids = term.assigns.projection.room_order

    if ids == [] do
      term
    else
      index = Enum.find_index(ids, &(&1 == term.assigns.selected_room_id)) || 0
      selected_room_id = Enum.at(ids, Integer.mod(index + offset, length(ids)))
      Component.assign(term, selected_room_id: selected_room_id)
    end
  end

  @doc "Returns whether the room sidebar is visible at a terminal width."
  @spec show_sidebar?(integer()) :: boolean()
  def show_sidebar?(width), do: width >= 140

  @doc "Returns the selected room timeline element ID."
  @spec timeline_id(term()) :: String.t()
  def timeline_id(room_id), do: "timeline-#{room_id}"

  defp room_messages(nil, _projection), do: []

  defp room_messages(room, projection) do
    room.message_order
    |> Enum.reverse()
    |> Enum.map(fn message_id ->
      message = projection.messages[message_id]

      message
      |> Map.put(:invocation, projection.invocations[message.invocation_id])
      |> Map.put(:turn, projection.turns[message.turn_id])
    end)
  end

  defp message_width(width, true), do: max(width - 38, 24)
  defp message_width(width, false), do: max(width - 8, 16)
end
