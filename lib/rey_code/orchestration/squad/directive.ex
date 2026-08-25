defmodule ReyCode.Orchestration.Squad.Directive do
  @moduledoc "Operator guidance recorded on a running squad turn."

  @enforce_keys [:text, :phase, :cycle, :recorded_at]
  defstruct [:text, :phase, :cycle, :recorded_at]

  @type t :: %__MODULE__{
          text: String.t(),
          phase: String.t(),
          cycle: non_neg_integer(),
          recorded_at: term()
        }

  @doc "Converts a legacy or decoded directive map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = directive), do: directive

  def from_map(directive) when is_map(directive) do
    %__MODULE__{
      text: fetch(directive, :text),
      phase: fetch(directive, :phase),
      cycle: fetch(directive, :cycle, 0),
      recorded_at: fetch(directive, :recorded_at)
    }
  end

  defp fetch(directive, key, default \\ nil) when is_atom(key) do
    case Map.fetch(directive, key) do
      {:ok, value} -> value
      :error -> Map.get(directive, Atom.to_string(key), default)
    end
  end
end
