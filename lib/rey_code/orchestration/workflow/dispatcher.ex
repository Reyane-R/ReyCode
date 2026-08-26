defmodule ReyCode.Orchestration.Workflow.Dispatcher do
  @moduledoc "Selects the orchestration workflow for a turn mode."

  alias ReyCode.Orchestration.Mode

  @doc "Returns the workflow module responsible for a mode."
  @spec for_mode(Mode.id()) :: module()
  def for_mode(mode), do: Mode.workflow(mode)
end
