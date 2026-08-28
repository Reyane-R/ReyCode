defmodule ReyCode.TUI.AgentHub do
  @moduledoc "Live operator view and controls for delegated child Invocations."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Projection}
  alias ReyCode.TUI.{MergeReview, SlashPalette}

  @spec initial() :: map()
  def initial, do: %{index: 0}

  @spec open(map()) :: map()
  def open(term) do
    if children(term) == [] do
      SlashPalette.close(term, "No delegated child Invocations")
    else
      term
      |> Component.assign(modal: :agent_hub, slash: nil, agent_hub: initial(), notice: nil)
      |> View.focus("prompt")
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, term}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(children(term))
    index = Integer.mod(term.assigns.agent_hub.index + offset, count)
    {:noreply, Component.assign(term, agent_hub: %{index: index})}
  end

  def handle_input(key, term) when key in ["c", "C"] do
    case selected_child(term) do
      nil ->
        {:noreply, term}

      child ->
        cancel_fun = Map.get(term.assigns, :cancel_child, &Engine.cancel_turn/3)

        case cancel_fun.(
               child.turn_id,
               "Cancelled by Operator in Agent Hub",
               term.assigns.engine
             ) do
          :ok ->
            {:noreply, Component.assign(term, notice: "Child Invocation cancelled")}

          {:error, reason} ->
            {:noreply, Component.assign(term, notice: "Could not cancel child: #{reason}")}
        end
    end
  end

  def handle_input(key, term) when key in ["m", "M"] do
    case selected_child(term) do
      %{pending_tool_review: %{tool: "merge"}} = child ->
        {:noreply, MergeReview.open(term, child)}

      nil ->
        {:noreply, term}

      _child ->
        {:noreply, Component.assign(term, notice: "Selected child has no patch awaiting review")}
    end
  end

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input("Enter", term), do: {:noreply, term}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns child Invocation rows in durable turn order."
  @spec children(map()) :: [map()]
  def children(%{assigns: assigns}), do: children(assigns)

  def children(%{projection: projection, selected_session_id: session_id}) do
    Projection.delegated_invocations(projection, session_id)
  end

  defp selected_child(term), do: Enum.at(children(term), term.assigns.agent_hub.index)

  defp close(term) do
    term
    |> Component.assign(modal: nil, agent_hub: initial(), notice: nil)
    |> View.focus("prompt")
  end

  attr :term, :map, required: true

  @doc "Renders live delegated child status and bounded controls."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Agent Hub</box>
        <box class="text-muted">Live delegated Invocation control.</box>
      </box>
      <box class="pt-3 w-full">
        <box
          :for={{child, index} <- Enum.with_index(children(@term))}
          class={row_class(index, @term.agent_hub.index)}
        >
          {marker(index, @term.agent_hub.index)} {child.participant.name} · {child.status} · {child.label}{peer_label(child)}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">
        Arrow keys or j/k move   M review patch   C cancel child   Esc close
      </box>
    </box>
    """
  end

  defp peer_label(child) do
    merge =
      if match?(%{pending_tool_review: %{tool: "merge"}}, child),
        do: " · awaits merge",
        else: ""

    messages =
      case Map.get(child, :coordination) do
        %{peer_messages: messages} -> messages
        _legacy -> Map.get(child, :peer_messages, [])
      end

    peer = if messages == [], do: "", else: " · #{length(messages)} peer messages"
    merge <> peer
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
