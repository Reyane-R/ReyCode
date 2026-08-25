defmodule ReyCode.Orchestration.ToolAsk do
  @moduledoc """
  The pending owner decision recorded when a tool execution needs approval.

  Requests are addressed by `request_id`, so a stale view can never resolve
  a different ask than the one displayed.
  """

  @enforce_keys [:request_id, :tool, :arguments, :workspace, :requested_at]
  defstruct [:request_id, :tool, :arguments, :workspace, :requested_at]

  @type t :: %__MODULE__{
          request_id: String.t(),
          tool: String.t(),
          arguments: map(),
          workspace: String.t(),
          requested_at: term()
        }

  @doc "Converts a legacy or decoded tool-ask map into the current record."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = ask), do: ask

  def from_map(ask) when is_map(ask) do
    %__MODULE__{
      request_id: ask[:request_id] || Map.get(ask, "request_id"),
      tool: ask[:tool] || Map.get(ask, "tool"),
      arguments: ask[:arguments] || Map.get(ask, "arguments", %{}),
      workspace: ask[:workspace] || Map.get(ask, "workspace"),
      requested_at: ask[:requested_at] || Map.get(ask, "requested_at")
    }
  end
end
