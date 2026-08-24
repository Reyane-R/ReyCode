defmodule ReyCode.Retry do
  @moduledoc "Fail-closed retry classification shared by production and simulation paths."

  alias ReyCode.Failure

  @doc "Returns true only when a typed Failure explicitly permits retry."
  @spec retryable?(term()) :: boolean()
  def retryable?(%Failure{} = failure), do: Failure.retryable?(failure)
  def retryable?(_error), do: false
end
