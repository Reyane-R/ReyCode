defmodule ReyCode.TUI.Workspace do
  @moduledoc "State transitions for the workspace-path modal."

  alias Breeze.{Component, View}

  @doc "Opens the selected room's workspace path."
  @spec open(map()) :: map()
  def open(term), do: Component.assign(term, modal: :workspace, slash: nil, notice: nil)

  @doc "Closes the workspace path and restores prompt focus."
  @spec close(map()) :: map()
  def close(term), do: term |> Component.assign(modal: nil) |> View.focus("prompt")
end
