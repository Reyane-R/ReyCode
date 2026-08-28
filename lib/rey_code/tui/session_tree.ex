defmodule ReyCode.TUI.SessionTree do
  @moduledoc "Bounded tree navigation for durable SessionFork relationships."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Session}
  alias ReyCode.TUI.{SlashPalette, State, TimeAgo}

  @max_row_count 256

  @spec initial() :: map()
  def initial, do: %{index: 0}

  @spec open(map()) :: map()
  def open(term) do
    if rows(term.assigns.projection) == [] do
      SlashPalette.close(term, "No Sessions yet")
    else
      term
      |> SlashPalette.clear()
      |> Component.assign(modal: :session_tree, session_tree: initial(), notice: nil)
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    selected = selected_row(term)

    next =
      term
      |> close()
      |> State.select_session(selected.session.id)
      |> View.focus("prompt")

    {:noreply, next}
  end

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(rows(term.assigns.projection))
    index = Integer.mod(term.assigns.session_tree.index + offset, count)
    {:noreply, Component.assign(term, session_tree: %{index: index})}
  end

  def handle_input(key, term) when key in ["f", "F"], do: fork_selected(term)
  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns roots followed by descendants in durable Session creation order."
  @spec rows(map()) :: [map()]
  def rows(projection) do
    ordered = Enum.map(projection.session_order, &projection.sessions[&1])
    ids = MapSet.new(projection.session_order)

    roots =
      Enum.filter(ordered, fn session ->
        is_nil(session.parent_session_id) or not MapSet.member?(ids, session.parent_session_id)
      end)

    children = Enum.group_by(ordered, & &1.parent_session_id)

    roots
    |> Enum.flat_map(&descendants(&1, children, 0, %{}))
    |> Enum.take(@max_row_count)
  end

  attr :term, :map, required: true

  @doc "Renders the SessionFork map and selected branch metadata."
  def modal(assigns) do
    tree_rows = rows(assigns.term.projection)
    selected = Enum.at(tree_rows, assigns.term.session_tree.index)
    assigns = assigns |> Map.put(:tree_rows, tree_rows) |> Map.put(:selected, selected)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-secondary pb-1">
        <box class="font-bold text-secondary">Session Tree</box>
        <box class="text-muted">Durable forks and rewind points</box>
      </box>
      <box class="pt-2 w-full overflow-hidden">
        <box
          :for={{row, index} <- Enum.with_index(@tree_rows)}
          class={row_class(index, @term.session_tree.index)}
        >
          {marker(index, @term.session_tree.index)} {indent(row.depth)}{branch(row.depth)}{row.session.title} · {message_count(row.session)} messages{current_label(row.session.id, @term.selected_session_id)}
        </box>
      </box>
      <box class="pt-2 w-full border-t border-muted">
        <box class="font-bold">{@selected.session.title}</box>
        <box class="text-muted">
          {Path.basename(@selected.session.workspace)} · {TimeAgo.format(@selected.session.created_at)}
        </box>
        <box :if={@selected.session.parent_session_id} class="text-muted">
          Forked from {@selected.session.parent_session_id} at sequence {@selected.session.forked_from_sequence}
        </box>
        <box :if={@selected.session.context_boundary_sequence > 0} class="text-warning">
          Context compacted through sequence {@selected.session.context_boundary_sequence}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-1 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">j/k move   Enter open   F fork selected   Esc close</box>
    </box>
    """
  end

  @spec descendants(Session.t(), map(), non_neg_integer(), map()) :: [map()]
  defp descendants(session, children, depth, visited) do
    if Map.has_key?(visited, session.id) do
      []
    else
      visited = Map.put(visited, session.id, true)
      row = %{session: session, depth: depth}

      nested =
        children
        |> Map.get(session.id, [])
        |> Enum.flat_map(&descendants(&1, children, depth + 1, visited))

      [row | nested]
    end
  end

  defp fork_selected(term) do
    selected = selected_row(term)

    case Engine.fork_session(
           selected.session.id,
           term.assigns.projection.sequence,
           term.assigns.engine
         ) do
      {:ok, session_id} ->
        next =
          term
          |> Component.assign(modal: nil, session_tree: initial(), notice: "Session forked")
          |> State.select_session(session_id)
          |> View.focus("prompt")

        {:noreply, next}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not fork Session: #{reason}")}
    end
  end

  defp selected_row(term),
    do: term.assigns.projection |> rows() |> Enum.at(term.assigns.session_tree.index)

  defp close(term),
    do:
      term
      |> Component.assign(modal: nil, session_tree: initial(), notice: nil)
      |> View.focus("prompt")

  defp indent(depth), do: String.duplicate("  ", depth)
  defp branch(0), do: "● "
  defp branch(_depth), do: "└─● "
  defp message_count(session), do: length(session.message_order)
  defp current_label(id, id), do: " · current"
  defp current_label(_id, _current_id), do: ""
  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-secondary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
