defmodule ReyCode.TUI.MergeReview do
  @moduledoc "Owner Apply/Discard surface for isolated delegation patches."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.Notice

  @visible_line_count 24

  @spec initial() :: map()
  def initial, do: %{child_invocation_id: nil, offset: 0, decision: nil}

  @spec open(map(), map()) :: map()
  def open(term, child) do
    Component.assign(term,
      modal: :merge_review,
      merge_review: %{initial() | child_invocation_id: child.id},
      notice: nil
    )
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{merge_review: %{decision: nil}}} = term) do
    {:noreply,
     Component.assign(term,
       notice: Notice.new(:info, "Choose Apply with Left or Discard with Right, then press Enter")
     )}
  end

  def submit(%{assigns: %{merge_review: %{decision: decision}}} = term)
      when decision in [:apply, :discard],
      do: resolve(term, decision)

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "k"] do
    offset = max(term.assigns.merge_review.offset - 1, 0)

    {:noreply,
     Component.assign(term, merge_review: %{term.assigns.merge_review | offset: offset})}
  end

  def handle_input(key, term) when key in ["ArrowDown", "j"] do
    offset = min(term.assigns.merge_review.offset + 1, max(diff_line_count(term) - 1, 0))

    {:noreply,
     Component.assign(term, merge_review: %{term.assigns.merge_review | offset: offset})}
  end

  def handle_input(key, term) when key in ["ArrowLeft", "ArrowRight"] do
    decision = if key == "ArrowLeft", do: :apply, else: :discard

    {:noreply,
     Component.assign(term,
       merge_review: %{term.assigns.merge_review | decision: decision},
       notice: nil
     )}
  end

  def handle_input("Enter", term), do: submit(term)
  def handle_input(key, term) when key in ["a", "A"], do: resolve(term, :apply)
  def handle_input(key, term) when key in ["d", "D"], do: resolve(term, :discard)
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    child = child(assigns.term)
    review = child.pending_tool_review
    # Reserve space for the source warning, decision controls, and feedback.
    line_count = min(@visible_line_count, max(assigns.term.breeze.terminal.height - 18, 1))

    diff_lines =
      visible_diff_lines(review.arguments["diff"], assigns.term.merge_review.offset, line_count)

    assigns = assigns |> Map.put(:child, child) |> Map.put(:diff_lines, diff_lines)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-2 overflow-hidden">
      <box class="w-full border-b border-warning pb-1">
        <box class="font-bold text-warning">Worktree checkpoint · {@child.participant.name}</box>
        <box class="text-muted">No source changes have been applied.</box>
        <box class="text-warning">
          Apply modifies the source workspace; Discard removes the isolated patch.
        </box>
        <box class="text-muted">
          Source workspace: {@child.execution_context.isolation["source_workspace"]}
        </box>
      </box>
      <box class="pt-2 w-full bg-panel overflow-hidden">
        <box :for={line <- @diff_lines} class={diff_class(line)}>{line}</box>
      </box>
      <box class="pt-2 inline w-full border-t border-muted">
        <box class={decision_class(@term.merge_review.decision == :apply)}>
          {if @term.merge_review.decision == :apply do
            "[selected] "
          else
            "[ ] "
          end}A Apply patch
        </box>
        <box class={"pl-3 " <> decision_class(@term.merge_review.decision == :discard)}>
          {if @term.merge_review.decision == :discard do
            "[selected] "
          else
            "[ ] "
          end}D Discard patch
        </box>
      </box>
      <box class="text-muted">
        Left/Right choose · Enter confirms choice · A/D act now · j/k scroll · Esc back
      </box>
      <box :if={is_nil(@term.merge_review.decision)} class="text-warning">
        No action selected. Enter will not apply or discard.
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-1 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
    </box>
    """
  end

  defp resolve(term, decision) do
    child = child(term.assigns)

    case Engine.resolve_merge(child.id, decision, term.assigns.engine) do
      :ok ->
        {:noreply, close(term, Notice.new(:success, "Patch #{past_tense(decision)}"))}

      {:error, reason} ->
        {:noreply,
         Component.assign(term, notice: Notice.new(:error, "Could not #{decision}: #{reason}"))}
    end
  end

  defp close(term, notice \\ nil) do
    term
    |> Component.assign(modal: :agent_hub, merge_review: initial(), notice: notice)
    |> View.focus("prompt")
  end

  defp child(term), do: term.projection.invocations[term.merge_review.child_invocation_id]

  defp diff_line_count(term) do
    term.assigns
    |> child()
    |> Map.fetch!(:pending_tool_review)
    |> then(& &1.arguments["diff"])
    |> String.split("\n", trim: false)
    |> length()
  end

  defp visible_diff_lines(diff, offset, line_count) do
    diff
    |> String.split("\n", trim: false)
    |> Enum.slice(offset, line_count)
  end

  defp diff_class("+" <> _line), do: "text-success"
  defp diff_class("-" <> _line), do: "text-error"
  defp diff_class("@@" <> _line), do: "text-secondary"
  defp diff_class(_line), do: "text-muted"
  defp decision_class(true), do: "font-bold bg-warning text-bg"
  defp decision_class(false), do: "text-muted"
  defp past_tense(:apply), do: "applied"
  defp past_tense(:discard), do: "discarded"
end
