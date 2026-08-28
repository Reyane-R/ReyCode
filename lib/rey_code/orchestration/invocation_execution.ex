defmodule ReyCode.Orchestration.InvocationExecution do
  @moduledoc "Frozen workspace and delegated-output contract for one Invocation."

  alias ReyCode.Orchestration.ModelTier

  @fields [
    :workspace,
    :workspace_roots,
    :output_schema,
    :isolation,
    :model_tier,
    :merge_decision,
    :token_budget_tokens
  ]
  defstruct workspace: nil,
            workspace_roots: [],
            output_schema: nil,
            isolation: nil,
            merge_decision: nil,
            model_tier: :default,
            token_budget_tokens: 100_000

  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          workspace_roots: [String.t()],
          output_schema: map() | nil,
          isolation: map() | nil,
          merge_decision: :apply | :discard | nil,
          model_tier: ModelTier.t(),
          token_budget_tokens: pos_integer()
        }

  @spec from_map(t() | map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = context), do: context
  def from_map(context) when is_map(context), do: struct!(__MODULE__, Map.take(context, @fields))
end
