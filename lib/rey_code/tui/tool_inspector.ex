defmodule ReyCode.TUI.ToolInspector do
  @moduledoc "Bounded list and detail inspector for projected ToolRuns."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.ToolRun
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.TUI.{Notice, SlashPalette}

  @max_run_count 256
  @max_detail_bytes 32_768
  @visible_line_count 22

  @spec initial() :: map()
  def initial, do: %{step: :list, index: 0, offset: 0}

  @spec open(map()) :: map()
  def open(term) do
    if rows(term.assigns) == [] do
      SlashPalette.close(term, Notice.new(:info, "No ToolRuns in this Session"))
    else
      term
      |> SlashPalette.clear()
      |> Component.assign(modal: :tool_inspector, tool_inspector: initial(), notice: nil)
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{tool_inspector: %{step: :list}}} = term),
    do: {:noreply, put_step(term, :detail)}

  def submit(term), do: {:noreply, term}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, %{assigns: %{tool_inspector: %{step: :list}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(rows(term.assigns))
    index = Integer.mod(term.assigns.tool_inspector.index + offset, count)

    {:noreply,
     Component.assign(term, tool_inspector: %{term.assigns.tool_inspector | index: index})}
  end

  def handle_input(key, %{assigns: %{tool_inspector: %{step: :detail}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k", "PageUp", "PageDown"] do
    delta = scroll_delta(key)
    maximum = max(detail_line_count(term) - @visible_line_count, 0)
    offset = (term.assigns.tool_inspector.offset + delta) |> max(0) |> min(maximum)

    {:noreply,
     Component.assign(term, tool_inspector: %{term.assigns.tool_inspector | offset: offset})}
  end

  def handle_input("Enter", term), do: submit(term)

  def handle_input("Escape", %{assigns: %{tool_inspector: %{step: :detail}}} = term),
    do: {:noreply, put_step(term, :list)}

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Returns newest ToolRuns in durable Session message and run order."
  @spec rows(map()) :: [map()]
  def rows(%{projection: projection, selected_session_id: session_id}) do
    case Map.get(projection.sessions, session_id) do
      nil ->
        []

      session ->
        session.message_order
        |> Enum.reverse()
        |> Enum.map(&projection.messages[&1])
        |> Enum.filter(&(&1 && &1.invocation_id))
        |> Enum.map(&projection.invocations[&1.invocation_id])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.flat_map(&invocation_runs/1)
        |> Enum.take(@max_run_count)
    end
  end

  attr :term, :map, required: true

  @doc "Renders the ToolRun list or selected run detail."
  def modal(assigns) do
    selected = selected_row(assigns.term)
    detail_lines = visible_detail_lines(assigns.term)

    assigns =
      assigns
      |> Map.put(:rows, rows(assigns.term))
      |> Map.put(:selected, selected)
      |> Map.put(:detail_lines, detail_lines)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-primary pb-1">
        <box class="font-bold text-primary">ToolRun Inspector</box>
        <box class="text-muted">Durable authorization, arguments, output, and ownership</box>
      </box>
      <box :if={@term.tool_inspector.step == :list} class="pt-2 w-full overflow-hidden">
        <box
          :for={{row, index} <- Enum.with_index(@rows)}
          class={row_class(index, @term.tool_inspector.index, row.run.status)}
        >
          {marker(index, @term.tool_inspector.index)} {row.run.tool} · {row.run.status} · {row.invocation.participant.name} · round {row.run.round_index}
        </box>
      </box>
      <box :if={@term.tool_inspector.step == :detail} class="pt-2 w-full overflow-hidden">
        <box class="font-bold">{@selected.run.tool} · {@selected.run.status}</box>
        <box class="text-muted">
          Invocation {@selected.invocation.id} · {@selected.invocation.participant.name}
        </box>
        <box :for={line <- @detail_lines} class={detail_class(line)}>{line}</box>
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-1 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-2 text-muted">{controls(@term.tool_inspector.step)}</box>
    </box>
    """
  end

  defp invocation_runs(invocation) do
    invocation
    |> Map.get(:tool_run_order, [])
    |> Enum.reverse()
    |> Enum.flat_map(fn run_id ->
      case Map.get(Map.get(invocation, :tool_runs, %{}), run_id) do
        nil -> []
        run -> [%{invocation: invocation, run: ToolRun.from_map(Map.put_new(run, :id, run_id))}]
      end
    end)
  end

  defp selected_row(term) do
    assigns = term_assigns(term)
    assigns |> rows() |> Enum.at(assigns.tool_inspector.index)
  end

  defp detail(term) do
    %{invocation: invocation, run: run} = selected_row(term)

    [
      "Authorization  #{run.authorization || "—"}",
      "Resolution     #{run.resolution || "—"}",
      "Workspace      #{run.workspace || "—"}",
      "Requested      #{run.requested_at || "—"}",
      "Started        #{run.started_at || "—"}",
      "Completed      #{run.completed_at || "—"}",
      "Arguments",
      encode(run.arguments),
      "Output",
      output(run.result),
      "Error",
      encode(run.error),
      "Invocation",
      "#{invocation.id} · attempt #{invocation.attempt} · #{invocation.status}"
    ]
    |> Enum.join("\n")
    |> TextBuffer.truncate_utf8(@max_detail_bytes)
  end

  defp visible_detail_lines(term) do
    assigns = term_assigns(term)

    if assigns.tool_inspector.step == :detail do
      term
      |> detail()
      |> String.split("\n", trim: false)
      |> Enum.slice(assigns.tool_inspector.offset, @visible_line_count)
    else
      []
    end
  end

  defp detail_line_count(term),
    do: term |> detail() |> String.split("\n", trim: false) |> length()

  defp output(nil), do: "—"

  defp output(result) when is_map(result),
    do: Map.get(result, "output", Map.get(result, :output, encode(result)))

  defp output(result), do: to_string(result)

  defp encode(nil), do: "—"

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value, limit: 20, printable_limit: 2_048)
    end
  end

  defp put_step(term, step),
    do:
      Component.assign(term,
        tool_inspector: %{term.assigns.tool_inspector | step: step, offset: 0}
      )

  defp close(term),
    do:
      term
      |> Component.assign(modal: nil, tool_inspector: initial(), notice: nil)
      |> View.focus("prompt")

  defp term_assigns(%{assigns: assigns}), do: assigns
  defp term_assigns(assigns), do: assigns

  defp scroll_delta(key) when key in ["ArrowUp", "k"], do: -1
  defp scroll_delta(key) when key in ["ArrowDown", "j"], do: 1
  defp scroll_delta("PageUp"), do: -@visible_line_count
  defp scroll_delta("PageDown"), do: @visible_line_count
  defp controls(:list), do: "j/k move   Enter inspect   Esc close"
  defp controls(:detail), do: "j/k or PageUp/PageDown scroll   Esc runs"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
  defp row_class(index, index, _status), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected, :failed), do: "w-full px-1 text-error"
  defp row_class(_index, _selected, _status), do: "w-full px-1 text-muted"
  defp detail_class("Error"), do: "pt-1 font-bold text-error"
  defp detail_class("Arguments"), do: "pt-1 font-bold text-secondary"
  defp detail_class("Output"), do: "pt-1 font-bold text-primary"
  defp detail_class("Invocation"), do: "pt-1 font-bold"
  defp detail_class(_line), do: "text-muted"
end
