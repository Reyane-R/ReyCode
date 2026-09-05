defmodule ReyCode.TUI.Decisions do
  @moduledoc "Bounded Operator browser for workspace decisions and assumptions."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Memory.Store
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.TUI.{Notice, SlashPalette}

  @kinds ~w(decision assumption)
  @max_entry_count 100
  @max_detail_bytes 32_768
  @visible_line_count 22

  @spec initial() :: map()
  def initial, do: %{step: :list, index: 0, offset: 0}

  @spec open(map()) :: map()
  def open(term) do
    case entries(term) do
      {:ok, _entries} ->
        term
        |> SlashPalette.clear()
        |> Component.assign(modal: :decisions, decisions: initial(), notice: nil)

      {:error, reason} ->
        SlashPalette.close(term, Notice.new(:error, "Could not read decisions: #{reason}"))
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{decisions: %{step: :list}}} = term) do
    if current_entry(term),
      do: {:noreply, put_step(term, :detail)},
      else: {:noreply, term}
  end

  def submit(term), do: {:noreply, term}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, %{assigns: %{decisions: %{step: :list}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    case entry_list(term) do
      [] ->
        {:noreply, term}

      entries ->
        offset = if key in ["ArrowUp", "k"], do: -1, else: 1
        index = Integer.mod(term.assigns.decisions.index + offset, length(entries))
        {:noreply, Component.assign(term, decisions: %{term.assigns.decisions | index: index})}
    end
  end

  def handle_input(key, %{assigns: %{decisions: %{step: :detail}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k", "PageUp", "PageDown"] do
    delta = scroll_delta(key)
    maximum = max(detail_line_count(term) - @visible_line_count, 0)
    offset = (term.assigns.decisions.offset + delta) |> max(0) |> min(maximum)
    {:noreply, Component.assign(term, decisions: %{term.assigns.decisions | offset: offset})}
  end

  def handle_input(key, term) when key in ["y", "Y"], do: invalidate(term)
  def handle_input("Enter", term), do: submit(term)

  def handle_input("Escape", %{assigns: %{decisions: %{step: :detail}}} = term),
    do: {:noreply, put_step(term, :list)}

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  @doc "Renders the decision list or selected rationale detail."
  def modal(assigns) do
    entries = entry_list(assigns.term)
    selected = Enum.at(entries, assigns.term.decisions.index)
    detail_lines = visible_detail_lines(assigns.term)

    assigns =
      assigns
      |> Map.put(:entries, entries)
      |> Map.put(:selected, selected)
      |> Map.put(:detail_lines, detail_lines)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-secondary pb-1">
        <box class="font-bold text-secondary">Decisions & assumptions</box>
        <box class="text-muted">Workspace trace · {workspace(@term)}</box>
      </box>
      <box :if={@term.decisions.step == :list} class="pt-2 w-full overflow-hidden">
        <box :if={@entries == []} class="text-muted">No decisions or assumptions recorded.</box>
        <box
          :for={{entry, index} <- Enum.with_index(@entries)}
          class={row_class(index, @term.decisions.index, entry.active)}
        >
          {marker(index, @term.decisions.index)} [{entry.kind}] {entry.key} · {status(entry)} · {entry.created_at}
        </box>
      </box>
      <box :if={@term.decisions.step == :detail and @selected} class="pt-2 w-full overflow-hidden">
        <box class="font-bold">[{@selected.kind}] {@selected.key}</box>
        <box class={if @selected.active do
      "text-muted"
    else
      "text-warning"
    end}>
          {status(@selected)} · {@selected.created_at}
        </box>
        <box :for={line <- @detail_lines} class={detail_class(line)}>{line}</box>
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-1 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-2 text-muted">{controls(@term.decisions.step)}</box>
    </box>
    """
  end

  defp entries(term) do
    assigns = term_assigns(term)
    Store.list(workspace(assigns), @kinds, @max_entry_count, memory_store(assigns))
  end

  defp entry_list(term) do
    case entries(term) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp current_entry(term) do
    assigns = term_assigns(term)
    Enum.at(entry_list(assigns), assigns.decisions.index)
  end

  defp invalidate(term) do
    case current_entry(term) do
      nil ->
        {:noreply, term}

      %{active: false} ->
        {:noreply,
         Component.assign(term, notice: Notice.new(:info, "Decision is already invalidated"))}

      entry ->
        case Store.forget(workspace(term.assigns), entry.key, memory_store(term.assigns)) do
          :ok ->
            {:noreply,
             Component.assign(term, notice: Notice.new(:success, "Invalidated #{entry.key}"))}

          {:error, reason} ->
            {:noreply,
             Component.assign(term, notice: Notice.new(:error, "Could not invalidate: #{reason}"))}
        end
    end
  end

  defp detail(term) do
    term
    |> current_entry()
    |> detail_text()
    |> TextBuffer.truncate_utf8(@max_detail_bytes)
  end

  defp detail_text(nil), do: ""

  defp detail_text(entry) do
    case Jason.decode(entry.value) do
      {:ok, value} when is_map(value) ->
        [
          section("Statement", value["statement"]),
          section("Rationale", value["rationale"]),
          section("Alternatives", value["alternatives"]),
          section("Evidence", value["evidence"]),
          section("Tags", Enum.join(entry.tags, ", "))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      _raw ->
        entry.value <> "\nTags\n" <> Enum.join(entry.tags, ", ")
    end
  end

  defp section(_title, nil), do: nil
  defp section(title, value), do: "#{title}\n#{value}"

  defp visible_detail_lines(term) do
    assigns = term_assigns(term)

    if assigns.decisions.step == :detail do
      term
      |> detail()
      |> String.split("\n", trim: false)
      |> Enum.slice(assigns.decisions.offset, @visible_line_count)
    else
      []
    end
  end

  defp detail_line_count(term),
    do: term |> detail() |> String.split("\n", trim: false) |> length()

  defp put_step(term, step),
    do: Component.assign(term, decisions: %{term.assigns.decisions | step: step, offset: 0})

  defp close(term),
    do:
      term
      |> Component.assign(modal: nil, decisions: initial(), notice: nil)
      |> View.focus("prompt")

  defp workspace(%{assigns: assigns}), do: workspace(assigns)
  defp workspace(assigns), do: assigns.projection.sessions[assigns.selected_session_id].workspace
  defp memory_store(assigns), do: Map.get(assigns, :memory_store, Store)
  defp term_assigns(%{assigns: assigns}), do: assigns
  defp term_assigns(assigns), do: assigns
  defp status(%{active: true}), do: "active"
  defp status(%{active: false}), do: "invalidated"
  defp controls(:list), do: "j/k move   Enter inspect   Y invalidate   Esc close"
  defp controls(:detail), do: "j/k or PageUp/PageDown scroll   Y invalidate   Esc list"
  defp scroll_delta(key) when key in ["ArrowUp", "k"], do: -1
  defp scroll_delta(key) when key in ["ArrowDown", "j"], do: 1
  defp scroll_delta("PageUp"), do: -@visible_line_count
  defp scroll_delta("PageDown"), do: @visible_line_count
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
  defp row_class(index, index, _active), do: "w-full px-1 bg-panel font-bold text-secondary"
  defp row_class(_index, _selected, false), do: "w-full px-1 text-warning"
  defp row_class(_index, _selected, true), do: "w-full px-1 text-muted"
  defp detail_class("Statement"), do: "pt-1 font-bold text-secondary"
  defp detail_class("Rationale"), do: "pt-1 font-bold"
  defp detail_class("Alternatives"), do: "pt-1 font-bold"
  defp detail_class("Evidence"), do: "pt-1 font-bold text-primary"
  defp detail_class("Tags"), do: "pt-1 font-bold text-muted"
  defp detail_class(_line), do: "text-muted"
end
