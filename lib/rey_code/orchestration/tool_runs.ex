defmodule ReyCode.Orchestration.ToolRuns do
  @moduledoc "Queries over the tool runs projected onto one invocation."

  @terminal [:completed, :failed, :denied, :interrupted]

  @doc "Returns the first tool run still awaiting owner approval."
  @spec awaiting(map()) :: map() | nil
  def awaiting(invocation) do
    invocation
    |> ordered_runs()
    |> Enum.find(&(&1.status == :awaiting_approval))
  end

  @doc "Whether any tool run is awaiting owner approval."
  @spec awaiting?(map()) :: boolean()
  def awaiting?(invocation), do: awaiting(invocation) != nil

  @doc "Whether any tool run is mid-execution (indeterminate after a crash)."
  @spec started?(map()) :: boolean()
  def started?(invocation) do
    invocation
    |> ordered_runs()
    |> Enum.any?(&(&1.status == :running))
  end

  @doc "Returns the tool run recorded for a provider tool call ID."
  @spec run_for_call(map(), String.t()) :: map() | nil
  def run_for_call(invocation, tool_call_id) do
    invocation
    |> ordered_runs()
    |> Enum.find(&(&1.tool_call_id == tool_call_id))
  end

  @doc "Whether a run status is terminal."
  @spec terminal?(atom()) :: boolean()
  def terminal?(status), do: status in @terminal

  @doc "Encodes a terminal run as the JSON tool-result content for the next round."
  @spec result_content(map()) :: String.t()
  def result_content(%{status: :completed, result: result}) do
    Jason.encode!(%{
      "ok" => true,
      "output" => result["output"],
      "error" => nil,
      "truncated" => !!result["truncated"],
      "metadata" => result["metadata"] || %{}
    })
  end

  def result_content(%{status: status, error: error, result: result}) do
    Jason.encode!(%{
      "ok" => false,
      "output" => nil,
      "error" => error || Atom.to_string(status),
      "truncated" => !!result["truncated"],
      "metadata" => (result && result["metadata"]) || %{}
    })
  end

  def result_content(%{status: status, error: error}) do
    Jason.encode!(%{
      "ok" => false,
      "output" => nil,
      "error" => error || Atom.to_string(status),
      "truncated" => false,
      "metadata" => %{}
    })
  end

  defp ordered_runs(invocation) do
    invocation
    |> Map.get(:tool_runs, %{})
    |> Map.take(invocation |> Map.get(:tool_run_order, []) |> Enum.reverse())
    |> Map.values()
  end
end
