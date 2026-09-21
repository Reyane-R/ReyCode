defmodule ReyCode.Orchestration.InvocationExecution do
  @moduledoc "Workspace, delegated-output, and provider-context state for one Invocation."

  alias ReyCode.Orchestration.{InvocationContextBoundary, ModelTier}

  @fields [
    :workspace,
    :workspace_roots,
    :output_schema,
    :isolation,
    :model_tier,
    :merge_decision,
    :token_budget_tokens,
    :context_boundary
  ]
  defstruct workspace: nil,
            workspace_roots: [],
            output_schema: nil,
            isolation: nil,
            merge_decision: nil,
            model_tier: :default,
            # Retained only for decoding historical events/checkpoints; never enforced.
            token_budget_tokens: nil,
            context_boundary: nil

  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          workspace_roots: [String.t()],
          output_schema: map() | nil,
          isolation: map() | nil,
          merge_decision: :apply | :discard | nil,
          model_tier: ModelTier.t(),
          token_budget_tokens: pos_integer() | nil,
          context_boundary: InvocationContextBoundary.t() | nil
        }

  @spec from_map(t() | map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = context), do: context

  def from_map(context) when is_map(context) do
    context = struct!(__MODULE__, Map.take(context, @fields))
    %{context | context_boundary: InvocationContextBoundary.from_map(context.context_boundary)}
  end
end
