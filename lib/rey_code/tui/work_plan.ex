defmodule ReyCode.TUI.WorkPlan do
  @moduledoc "Read-only TUI projection of the newest Invocation WorkPlan."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Projection
  alias ReyCode.TUI.SlashPalette

  @spec open(map()) :: map()
  def open(term) do
    invocation =
      Projection.work_plan_invocation(term.assigns.projection, term.assigns.selected_room_id)

    if invocation do
      term
      |> SlashPalette.clear()
      |> Component.assign(
        modal: :work_plan,
        work_plan_invocation_id: invocation.id,
        notice: nil
      )
    else
      SlashPalette.close(term, "No Invocation has a WorkPlan")
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, term}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    invocation = assigns.term.projection.invocations[assigns.term.work_plan_invocation_id]
    assigns = Map.put(assigns, :plan, invocation.coordination.work_plan)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">WorkPlan · {invocation_name(@term)}</box>
        <box class="text-muted">Durable provider-maintained progress; Esc close</box>
      </box>
      <box :for={phase <- @plan.phases} class="pt-2 w-full">
        <box class="font-bold">{phase.name}</box>
        <box :for={item <- phase.items} class={item_class(item.status)}>
          {status_marker(item.status)} {item.name}{blocked_reason(item)}
        </box>
      </box>
    </box>
    """
  end

  defp close(term) do
    term
    |> Component.assign(modal: nil, work_plan_invocation_id: nil, notice: nil)
    |> View.focus("prompt")
  end

  defp invocation_name(term),
    do: term.projection.invocations[term.work_plan_invocation_id].participant.name

  defp item_class(:in_progress), do: "pl-1 text-primary font-bold"
  defp item_class(:blocked), do: "pl-1 text-warning"
  defp item_class(_status), do: "pl-1 text-muted"

  defp status_marker(:pending), do: "○"
  defp status_marker(:in_progress), do: "▶"
  defp status_marker(:blocked), do: "Ⅱ"
  defp status_marker(:completed), do: "✓"
  defp status_marker(:dropped), do: "×"

  defp blocked_reason(%{status: :blocked, blocked_reason: reason}), do: " · #{reason}"
  defp blocked_reason(_item), do: ""
end
