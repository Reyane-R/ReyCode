defmodule ReyCode.Orchestration.Workflow.Dispatcher do
  @moduledoc "Selects the orchestration workflow for a turn mode."

  @doc "Returns the workflow module responsible for a mode."
  @spec for_mode(atom()) :: module()
  def for_mode(:compare), do: ReyCode.Orchestration.Workflow.Compare
  def for_mode(:debate), do: ReyCode.Orchestration.Workflow.Debate
  def for_mode(:fan_out), do: ReyCode.Orchestration.Workflow.FanOut
  def for_mode(:squad), do: ReyCode.Orchestration.Workflow.Squad
end
