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
    AgentHub,
    AgentProfile,
    Artifacts,
    Cancellation,
    ContextBoundary,
    Decisions,
    Delegation,
    Help,
    Hotkeys,
    MergeReview,
    ModelPicker,
    ModelTiers,
    OperatorQuestion,
    PromptHistory,
    SessionPicker,
    SessionTree,
    Settings,
    SlashPalette,
    ToolInspector,
    ToolReview,
    WorkPlan,
    Workspace
  }

  alias ReyCode.TUI.Components.SettingsModal

  @registry %{
    artifacts: Artifacts,
    agent_hub: AgentHub,
    agent_profile: AgentProfile,
    context_boundary: ContextBoundary,
    delegation: Delegation,
    decisions: Decisions,
    model_picker: ModelPicker,
    merge_review: MergeReview,
    hotkeys: Hotkeys,
    model_tiers: ModelTiers,
    operator_question: OperatorQuestion,
    session_picker: SessionPicker,
    prompt_history: PromptHistory,
    settings: Settings,
    session_tree: SessionTree,
    workspace: Workspace,
    cancel: Cancellation,
    tool_review: ToolReview,
    tool_inspector: ToolInspector,
    slash: SlashPalette,
    help: Help,
    work_plan: WorkPlan
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

  defp dispatch(:artifacts, assigns), do: Artifacts.modal(assigns)

  defp dispatch(:agent_hub, assigns), do: AgentHub.modal(assigns)
  defp dispatch(:agent_profile, assigns), do: AgentProfile.modal(assigns)
  defp dispatch(:context_boundary, assigns), do: ContextBoundary.modal(assigns)
  defp dispatch(:decisions, assigns), do: Decisions.modal(assigns)
  defp dispatch(:delegation, assigns), do: Delegation.modal(assigns)
  defp dispatch(:hotkeys, assigns), do: Hotkeys.modal(assigns)
  defp dispatch(:model_picker, assigns), do: ModelPicker.modal(assigns)
  defp dispatch(:merge_review, assigns), do: MergeReview.modal(assigns)
  defp dispatch(:model_tiers, assigns), do: ModelTiers.modal(assigns)
  defp dispatch(:operator_question, assigns), do: OperatorQuestion.modal(assigns)
  defp dispatch(:prompt_history, assigns), do: PromptHistory.modal(assigns)
  defp dispatch(:session_picker, assigns), do: SessionPicker.modal(assigns)
  defp dispatch(:session_tree, assigns), do: SessionTree.modal(assigns)
  defp dispatch(:workspace, assigns), do: Workspace.modal(assigns)
  defp dispatch(:settings, assigns), do: SettingsModal.modal(assigns)
  defp dispatch(:cancel, assigns), do: Cancellation.modal(assigns)
  defp dispatch(:tool_review, assigns), do: ToolReview.modal(assigns)
  defp dispatch(:tool_inspector, assigns), do: ToolInspector.modal(assigns)
  defp dispatch(:help, assigns), do: Help.modal(assigns)
  defp dispatch(:work_plan, assigns), do: WorkPlan.modal(assigns)
  defp dispatch(_modal, assigns), do: empty(assigns)
  defp empty(assigns), do: ~H""
end
