defmodule ReyCode.Orchestration.Squad.Retry do
  @moduledoc "A recorded provider retry or leader rework in the orchestration projection."

  @enforce_keys [:role_id, :attempt, :kind, :phase, :cycle, :reason]
  defstruct [:role_id, :attempt, :kind, :phase, :cycle, :reason]

  @type t :: %__MODULE__{
          role_id: String.t(),
          attempt: pos_integer(),
          kind: String.t(),
          phase: String.t(),
          cycle: non_neg_integer(),
          reason: String.t()
        }

  @doc "Converts a legacy or decoded retry map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = retry), do: retry

  def from_map(retry) when is_map(retry) do
    %__MODULE__{
      role_id: fetch(retry, :role_id) || fetch(retry, :seat_id),
      attempt: fetch(retry, :attempt),
      kind: fetch(retry, :kind, "provider_retry"),
      phase: fetch(retry, :phase),
      cycle: fetch(retry, :cycle, 0),
      reason: fetch(retry, :reason)
    }
  end

  defp fetch(retry, key, default \\ nil) when is_atom(key) do
    case Map.fetch(retry, key) do
      {:ok, value} -> value
      :error -> Map.get(retry, Atom.to_string(key), default)
    end
  end
end
