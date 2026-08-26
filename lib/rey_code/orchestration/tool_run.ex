defmodule ReyCode.Orchestration.ToolRun do
  @moduledoc "A durable tool execution record in an invocation projection."

  @fields [
    :id,
    :tool_call_id,
    :round_index,
    :tool,
    :arguments,
    :workspace,
    :authorization,
    :status,
    :resolution,
    :result,
    :error,
    :requested_at,
    :started_at,
    :completed_at,
    :child_invocation_id
  ]

  defstruct id: nil,
            tool_call_id: nil,
            round_index: nil,
            tool: nil,
            arguments: %{},
            workspace: nil,
            authorization: nil,
            status: nil,
            resolution: nil,
            result: nil,
            error: nil,
            requested_at: nil,
            started_at: nil,
            completed_at: nil,
            child_invocation_id: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          tool_call_id: String.t() | nil,
          round_index: non_neg_integer() | nil,
          tool: String.t() | atom() | nil,
          arguments: map(),
          workspace: String.t() | nil,
          authorization: atom() | nil,
          status: atom() | nil,
          resolution: atom() | nil,
          result: map() | nil,
          error: map() | nil,
          requested_at: term(),
          started_at: term(),
          completed_at: term(),
          child_invocation_id: String.t() | nil
        }

  @doc "Converts a decoded or legacy tool-run map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(run) when is_map(run) do
    struct!(__MODULE__, Map.take(run, @fields))
  end
end
