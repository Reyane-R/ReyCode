defmodule ReyCode.Retry do
  @moduledoc "Fail-closed retry classification shared by production and simulation paths."

  @doc "Returns true only when an error explicitly carries a literal retryable flag."
  @spec retryable?(term()) :: boolean()
  def retryable?(%{"retryable" => true}), do: true
  def retryable?(_error), do: false
end
