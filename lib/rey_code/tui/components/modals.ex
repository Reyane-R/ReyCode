defmodule ReyCode.TUI.Components.Modals do
  @moduledoc """
  Registry and selector pairing each modal with its interaction owner and renderer.

  Feature modules own state transitions, focus, submission, and event/input
  handling. Small features render themselves; larger renderers may live under
  `ReyCode.TUI.Components`. This module maps modal names to interaction owners
  and renders whichever modal is currently active.
  """

  use Breeze.Component

  alias ReyCode.TUI.{
    Cancellation,
    Directive,
    GateReview,
    NewRoom,
    Settings,
    SlashPalette,
    SquadStatus,
    ToolReview,
    Workspace
  }

  alias ReyCode.TUI.Components.SettingsModal

  @registry %{
    new_room: NewRoom,
    settings: Settings,
    workspace: Workspace,
    cancel: Cancellation,
    squad_dashboard: SquadStatus,
    directive: Directive,
    gate_review: GateReview,
    tool_review: ToolReview,
    slash: SlashPalette
  }

  @doc "Returns the owning feature module for an open modal."
  @spec module!(atom()) :: module()
  def module!(name), do: Map.fetch!(@registry, name)

  @doc "Renders only the active modal's component."
  def active(assigns) do
    term =
      case assigns do
        %{term: term} -> term
        %{__breeze_caller_assigns__: caller} -> caller
        _ -> %{}
      end

    dispatch(Map.get(term || %{}, :modal), Map.put(assigns, :term, term))
  end

  defp dispatch(:new_room, assigns), do: NewRoom.modal(assigns)
  defp dispatch(:settings, assigns), do: SettingsModal.modal(assigns)
  defp dispatch(:workspace, assigns), do: Workspace.modal(assigns)
  defp dispatch(:cancel, assigns), do: Cancellation.modal(assigns)
  defp dispatch(:squad_dashboard, assigns), do: SquadStatus.modal(assigns)
  defp dispatch(:directive, assigns), do: Directive.modal(assigns)
  defp dispatch(:gate_review, assigns), do: GateReview.modal(assigns)
  defp dispatch(:tool_review, assigns), do: ToolReview.modal(assigns)
  defp dispatch(_modal, assigns), do: empty(assigns)

  defp empty(assigns), do: ~H""
end
