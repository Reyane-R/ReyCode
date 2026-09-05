defmodule ReyCode.TUI.AgentHub do
  @moduledoc "Responsive roster and inspector for delegated child Invocations."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Invocation, ModelTier, Projection}
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.TUI.{MergeReview, Notice, SlashPalette}

  @wide_terminal_columns 100
  @inspector_page_line_count 18

  @spec initial() :: map()
  def initial, do: %{index: 0, panel: :roster, tree?: false, offset: 0}

  @spec open(map()) :: map()
  def open(term) do
    if children(term) == [] do
      SlashPalette.close(term, Notice.new(:info, "No delegated child Invocations"))
    else
      term
      |> Component.assign(modal: :agent_hub, slash: nil, agent_hub: initial(), notice: nil)
      |> View.focus("prompt")
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, toggle_inspector(term)}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, %{assigns: %{agent_hub: %{panel: :roster}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(display_rows(term))
    index = Integer.mod(term.assigns.agent_hub.index + offset, count)

    {:noreply,
     Component.assign(term,
       agent_hub: %{term.assigns.agent_hub | index: index, offset: 0}
     )}
  end

  def handle_input(key, %{assigns: %{agent_hub: %{panel: :inspector}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k", "PageUp", "PageDown"] do
    delta = inspector_delta(key)
    maximum = max(length(inspector_lines(term)) - @inspector_page_line_count, 0)
    offset = (term.assigns.agent_hub.offset + delta) |> max(0) |> min(maximum)
    {:noreply, Component.assign(term, agent_hub: %{term.assigns.agent_hub | offset: offset})}
  end

  def handle_input(key, term) when key in ["t", "T"] do
    state = term.assigns.agent_hub
    {:noreply, Component.assign(term, agent_hub: %{state | tree?: not state.tree?, index: 0})}
  end

  def handle_input("Tab", term), do: {:noreply, toggle_inspector(term)}

  def handle_input(key, term) when key in ["c", "C"] do
    case selected_child(term) do
      nil ->
        {:noreply, term}

      child ->
        cancel_fun = Map.get(term.assigns, :cancel_child, &Engine.cancel_turn/3)

        case cancel_fun.(child.turn_id, "Cancelled by Operator in Agent Hub", term.assigns.engine) do
          :ok ->
            {:noreply,
             Component.assign(term, notice: Notice.new(:success, "Child Invocation cancelled"))}

          {:error, reason} ->
            {:noreply,
             Component.assign(term,
               notice: Notice.new(:error, "Could not cancel child: #{reason}")
             )}
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
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:info, "Selected child has no patch awaiting review")
         )}
    end
  end

  def handle_input("Escape", %{assigns: %{agent_hub: %{panel: :inspector}}} = term) do
    if wide?(term), do: {:noreply, close(term)}, else: {:noreply, toggle_inspector(term)}
  end

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input("Enter", term), do: submit(term)
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns child Invocations in durable transcript order."
  @spec children(map()) :: [map()]
  def children(%{assigns: assigns}), do: children(assigns)

  def children(%{projection: projection, selected_session_id: session_id}) do
    Projection.delegated_invocations(projection, session_id)
  end

  attr :term, :map, required: true

  @doc "Renders a responsive roster with a selected-child inspector."
  def modal(assigns) do
    rows = display_rows(assigns.term)
    selected = selected_child(assigns.term)
    lines = visible_inspector_lines(assigns.term)

    assigns =
      assigns
      |> Map.put(:rows, rows)
      |> Map.put(:selected, selected)
      |> Map.put(:inspector_lines, lines)
      |> Map.put(:wide, wide?(assigns.term))

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Agent Hub</box>
        <box class="text-muted">{summary(@rows)} · {view_label(@term.agent_hub.tree?)}</box>
      </box>
      <box :if={@wide} class="grid grid-cols-2 w-full pt-2 overflow-hidden">
        <box class="w-full pr-2 border-r border-muted">
          <.roster rows={@rows} selected_index={@term.agent_hub.index}/>
        </box>
        <box class="w-full pl-2">
          <.inspector child={@selected} lines={@inspector_lines}/>
        </box>
      </box>
      <box :if={not @wide and @term.agent_hub.panel == :roster} class="pt-2 w-full overflow-hidden">
        <.roster rows={@rows} selected_index={@term.agent_hub.index}/>
      </box>
      <box
        :if={not @wide and @term.agent_hub.panel == :inspector}
        class="pt-2 w-full overflow-hidden"
      >
        <.inspector child={@selected} lines={@inspector_lines}/>
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-1 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-2 text-muted">
        j/k move or scroll   Enter/Tab inspector   T tree   M patch   C cancel   Esc back
      </box>
    </box>
    """
  end

  attr :rows, :list, required: true
  attr :selected_index, :integer, required: true

  defp roster(assigns) do
    ~H"""
    <box :for={{row, index} <- Enum.with_index(@rows)} class={row_class(index, @selected_index)}>
      {marker(index, @selected_index)} {String.duplicate("  ", row.depth)}{row.child.participant.name} · {row.child.status}{peer_label(row.child)} · {row.child.label}
    </box>
    """
  end

  attr :child, :map, required: true
  attr :lines, :list, required: true

  defp inspector(assigns) do
    ~H"""
    <box class="font-bold text-secondary">{@child.participant.name} · {@child.status}</box>
    <box :for={line <- @lines} class={inspector_class(line)}>{line}</box>
    """
  end

  defp display_rows(term) do
    assigns = term_assigns(term)
    invocations = children(assigns)

    if assigns.agent_hub.tree? do
      by_parent = Enum.group_by(invocations, & &1.delegated_from_invocation_id)
      ids = MapSet.new(invocations, & &1.id)

      invocations
      |> Enum.filter(fn child ->
        is_nil(child.delegated_from_invocation_id) or
          not MapSet.member?(ids, child.delegated_from_invocation_id)
      end)
      |> Enum.flat_map(&tree_rows(&1, by_parent, 0, %{}))
    else
      Enum.map(invocations, &%{child: &1, depth: 0})
    end
  end

  @spec tree_rows(Invocation.t(), map(), non_neg_integer(), map()) :: [map()]
  defp tree_rows(child, by_parent, depth, visited) do
    if Map.has_key?(visited, child.id) do
      []
    else
      visited = Map.put(visited, child.id, true)

      descendants =
        by_parent
        |> Map.get(child.id, [])
        |> Enum.flat_map(&tree_rows(&1, by_parent, depth + 1, visited))

      [%{child: child, depth: depth} | descendants]
    end
  end

  defp selected_child(term) do
    assigns = term_assigns(term)

    case Enum.at(display_rows(assigns), assigns.agent_hub.index) do
      %{child: child} -> child
      nil -> nil
    end
  end

  defp inspector_lines(term) do
    assigns = term_assigns(term)
    child = selected_child(assigns)
    run = current_run(child)
    usage = ModelTier.used_tokens(child)
    parent = Map.get(assigns.projection.invocations, child.delegated_from_invocation_id)

    [
      "Task        #{child.label}",
      "Participant #{child.participant.name}",
      "Invocation  #{child.id}",
      "Attempt     #{child.attempt}",
      "Parent      #{if(parent, do: parent.participant.name, else: "main")}",
      "Children    #{child_count(term, child.id)}",
      "Tokens      #{usage || "—"} / #{child.execution_context.token_budget_tokens}",
      "Tier        #{child.execution_context.model_tier}",
      "Tool        #{tool_label(run)}",
      "Arguments   #{argument_label(run)}",
      "Messages    #{peer_count(child)} peer",
      "Workspace   #{child.execution_context.workspace || "—"}",
      "Isolation   #{isolation_label(child)}",
      "Merge       #{merge_label(child)}",
      "Error       #{error_label(child)}"
    ]
  end

  defp visible_inspector_lines(term) do
    assigns = term_assigns(term)

    assigns
    |> inspector_lines()
    |> Enum.slice(assigns.agent_hub.offset, @inspector_page_line_count)
  end

  defp current_run(child) do
    runs = Enum.map(Enum.reverse(child.tool_run_order), &child.tool_runs[&1])

    Enum.find(runs, &(&1 && &1.status in [:running, :ready, :awaiting_approval])) ||
      Enum.find(runs, & &1)
  end

  defp toggle_inspector(term) do
    panel = if term.assigns.agent_hub.panel == :roster, do: :inspector, else: :roster
    Component.assign(term, agent_hub: %{term.assigns.agent_hub | panel: panel, offset: 0})
  end

  defp close(term) do
    term
    |> Component.assign(modal: nil, agent_hub: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp wide?(term), do: term_assigns(term).breeze.terminal.width >= @wide_terminal_columns

  defp child_count(term, id),
    do: Enum.count(children(term_assigns(term)), &(&1.delegated_from_invocation_id == id))

  defp term_assigns(%{assigns: assigns}), do: assigns
  defp term_assigns(assigns), do: assigns

  defp peer_count(%{coordination: %{peer_messages: messages}}), do: length(messages)
  defp peer_count(_child), do: 0
  defp tool_label(nil), do: "—"
  defp tool_label(run), do: "#{run.tool} · #{run.status}"
  defp argument_label(nil), do: "—"

  defp argument_label(run),
    do: run.arguments |> inspect(limit: 8, printable_limit: 256) |> TextBuffer.truncate_utf8(96)

  defp isolation_label(%{execution_context: %{isolation: nil}}), do: "none"
  defp isolation_label(%{execution_context: %{isolation: _isolation}}), do: "worktree"
  defp merge_label(%{pending_tool_review: %{tool: "merge"}}), do: "awaiting Owner"

  defp merge_label(%{execution_context: %{merge_decision: decision}}) when not is_nil(decision),
    do: decision

  defp merge_label(_child), do: "—"
  defp error_label(%{error: nil}), do: "—"
  defp error_label(%{error: %{message: message}}), do: TextBuffer.truncate_utf8(message, 96)
  defp error_label(%{error: error}), do: TextBuffer.truncate_utf8(inspect(error), 96)
  defp summary(rows), do: "#{length(rows)} delegated"
  defp view_label(true), do: "tree"
  defp view_label(false), do: "flat"

  defp peer_label(child) do
    merge =
      if match?(%{pending_tool_review: %{tool: "merge"}}, child), do: " · awaits merge", else: ""

    peer = if peer_count(child) == 0, do: "", else: " · #{peer_count(child)} peer"
    merge <> peer
  end

  defp inspector_delta(key) when key in ["ArrowUp", "k"], do: -1
  defp inspector_delta(key) when key in ["ArrowDown", "j"], do: 1
  defp inspector_delta("PageUp"), do: -@inspector_page_line_count
  defp inspector_delta("PageDown"), do: @inspector_page_line_count
  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
  defp inspector_class("Error       —"), do: "text-muted"
  defp inspector_class("Error       " <> _error), do: "text-error"
  defp inspector_class("Merge       awaiting Owner"), do: "text-warning"
  defp inspector_class(_line), do: "text-muted"
end
