defmodule ReyCode.TUI.PromptHistory do
  @moduledoc "Bounded search and draft restoration for prior Operator messages."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.TUI.{Notice, SlashPalette, State}

  @max_prompt_count 256
  @max_query_bytes 256

  @spec initial() :: map()
  def initial, do: %{index: 0, query: ""}
  @doc "Returns the local shell-style recall cursor for one composer."
  @spec recall_initial() :: map()
  def recall_initial, do: %{session_id: nil, index: nil, scratch: ""}

  @doc "Recalls an older or newer prompt when the composer contains one line."
  @spec recall(map(), :previous | :next) :: {:noreply, map()} | :continue
  def recall(term, direction) when direction in [:previous, :next] do
    draft = Map.get(term.assigns.drafts, term.assigns.selected_session_id, "")

    if String.contains?(draft, "\n") do
      :continue
    else
      recall_one_line(term, draft, direction)
    end
  end

  @spec open(map()) :: map()
  def open(term) do
    if prompts(term.assigns) == [] do
      SlashPalette.close(term, Notice.new(:info, "No prompt history in this Session"))
    else
      term
      |> SlashPalette.clear()
      |> Component.assign(modal: :prompt_history, prompt_history: initial(), notice: nil)
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    prompt = Enum.at(matches(term.assigns), term.assigns.prompt_history.index)

    next =
      term
      |> close()
      |> State.assign_draft(prompt)
      |> View.focus("prompt")

    {:noreply, next}
  end

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    move(term, if(key in ["ArrowUp", "k"], do: -1, else: 1))
  end

  def handle_input("Backspace", term) do
    update_query(term, drop_last(term.assigns.prompt_history.query))
  end

  def handle_input("Enter", term), do: submit(term)
  def handle_input("Escape", term), do: {:noreply, close(term)}

  def handle_input(key, term) when is_binary(key) do
    if String.length(key) == 1 and
         byte_size(term.assigns.prompt_history.query <> key) <= @max_query_bytes,
       do: update_query(term, term.assigns.prompt_history.query <> key),
       else: {:noreply, term}
  end

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns newest distinct Operator prompts from one selected Session."
  @spec prompts(map()) :: [String.t()]
  def prompts(%{projection: projection, selected_session_id: session_id}) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        []

      session ->
        session.message_order
        |> Enum.reverse()
        |> Enum.map(&projection.messages[&1])
        |> Enum.filter(&((&1 && &1.role == :user) and not is_nil(&1.turn_id)))
        |> Enum.map(& &1.body)
        |> Enum.uniq()
        |> Enum.take(@max_prompt_count)
    end
  end

  attr :term, :map, required: true

  def modal(assigns) do
    matched = matches(assigns.term)
    assigns = Map.put(assigns, :matches, matched)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-secondary pb-1">
        <box class="font-bold text-secondary">Prompt history</box>
        <box class="text-muted">Search prior Operator messages and restore one to the composer</box>
      </box>
      <box class="pt-2 font-bold">Search · {@term.prompt_history.query}</box>
      <box :if={@matches == []} class="pt-2 text-muted">No matching prompts</box>
      <box
        :for={{prompt, index} <- Enum.with_index(@matches)}
        class={row_class(index, @term.prompt_history.index)}
      >
        {marker(index, @term.prompt_history.index)} {one_line(prompt)}
      </box>
      <box class="pt-2 text-muted">
        Type to search   Backspace edit   j/k move   Enter restore   Esc close
      </box>
    </box>
    """
  end

  defp matches(%{assigns: assigns}), do: matches(assigns)

  defp matches(assigns) do
    query = String.downcase(assigns.prompt_history.query)

    assigns
    |> prompts()
    |> Enum.filter(&(query == "" or String.contains?(String.downcase(&1), query)))
  end

  defp recall_one_line(term, draft, direction) do
    history = prompts(term.assigns)
    recall = term.assigns.prompt_recall
    session_id = term.assigns.selected_session_id
    recall = if recall.session_id == session_id, do: recall, else: recall_initial()

    case recall_index(recall.index, direction, length(history)) do
      :unchanged ->
        :continue

      :scratch ->
        {:noreply,
         assign_recalled_draft(term, recall.scratch, %{recall_initial() | session_id: session_id})}

      index ->
        scratch = if is_nil(recall.index), do: draft, else: recall.scratch
        next = %{session_id: session_id, index: index, scratch: scratch}
        {:noreply, assign_recalled_draft(term, Enum.at(history, index), next)}
    end
  end

  defp recall_index(nil, :previous, count) when count > 0, do: 0
  defp recall_index(nil, _direction, _count), do: :unchanged

  defp recall_index(index, :previous, count) when index + 1 < count, do: index + 1
  defp recall_index(_index, :previous, _count), do: :unchanged
  defp recall_index(0, :next, _count), do: :scratch
  defp recall_index(index, :next, _count), do: index - 1

  defp assign_recalled_draft(term, draft, recall) do
    drafts = Map.put(term.assigns.drafts, term.assigns.selected_session_id, draft)
    Component.assign(term, drafts: drafts, prompt_recall: recall)
  end

  defp move(term, offset) do
    count = length(matches(term))

    if count == 0 do
      {:noreply, term}
    else
      index = Integer.mod(term.assigns.prompt_history.index + offset, count)

      {:noreply,
       Component.assign(term, prompt_history: %{term.assigns.prompt_history | index: index})}
    end
  end

  defp update_query(term, query) do
    {:noreply,
     Component.assign(term,
       prompt_history: %{term.assigns.prompt_history | query: query, index: 0}
     )}
  end

  defp close(term),
    do:
      term
      |> Component.assign(modal: nil, prompt_history: initial(), notice: nil)
      |> View.focus("prompt")

  defp drop_last(query), do: String.slice(query, 0, max(String.length(query) - 1, 0))

  defp one_line(prompt), do: prompt |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)
  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-secondary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
