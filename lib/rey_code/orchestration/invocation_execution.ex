defmodule ReyCode.Orchestration.InvocationExecution do
  @moduledoc "Frozen workspace and delegated-output contract for one Invocation."

  @fields [:workspace, :workspace_roots, :output_schema, :isolation]
  defstruct workspace: nil, workspace_roots: [], output_schema: nil, isolation: nil

  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          workspace_roots: [String.t()],
          output_schema: map() | nil,
          isolation: map() | nil
        }

  @spec from_map(t() | map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = context), do: context
  def from_map(context) when is_map(context), do: struct!(__MODULE__, Map.take(context, @fields))
end
