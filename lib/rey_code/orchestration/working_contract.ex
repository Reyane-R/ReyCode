defmodule ReyCode.Orchestration.WorkingContract do
  @moduledoc "Shared model-facing contract for traceable assumptions and decisions."

  @decision_memory """
  Treat assumptions and decisions as traceable work. When materially different paths require Operator judgment, use ask_operator. Otherwise, before proceeding on an unstated assumption or choosing among viable approaches, record it with memory using kind=assumption or kind=decision and cite concrete evidence. Repo-durable choices belong in DECISIONS.md through an approved edit; workspace rationale belongs in memory.
  """

  @doc "Returns the bounded assumption and decision recording contract."
  @spec decision_memory() :: String.t()
  def decision_memory, do: String.trim(@decision_memory)

  @doc "Appends the shared traceability contract to one model system prompt."
  @spec append(String.t()) :: String.t()
  def append(prompt), do: prompt <> "\n\n" <> decision_memory()
end
