defmodule ReyCode.Orchestration.ToolRuns do
  @moduledoc "Queries and transition validation for one invocation's tool runs."

  alias ReyCode.Provider.ToolCall

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

  @doc "Returns every tool run whose host execution had started."
  @spec running(map()) :: [map()]
  def running(invocation), do: Enum.filter(ordered_runs(invocation), &(&1.status == :running))

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

  @doc "Returns the next durable action for the latest provider tool-call batch."
  @spec next_action(map()) :: :none | {:new, ToolCall.t()} | {:existing, atom(), map()}
  def next_action(invocation) do
    case List.last(invocation.rounds) do
      nil ->
        :none

      round ->
        round.tool_calls
        |> List.wrap()
        |> Enum.map(&call_from_wire/1)
        |> Enum.find_value(:none, &actionable(invocation, &1))
    end
  end

  @doc "Fetches one projected run and validates its expected status."
  @spec fetch_for_transition(map(), String.t(), atom()) :: {:ok, map()} | {:error, atom()}
  def fetch_for_transition(invocation, run_id, expected_status) do
    case Map.get(invocation.tool_runs, run_id) do
      nil -> {:error, :tool_run_not_found}
      %{status: ^expected_status} = run -> {:ok, run}
      _run -> {:error, :invalid_tool_run_transition}
    end
  end

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

  defp actionable(invocation, call) do
    case run_for_call(invocation, call.id) do
      nil -> {:new, call}
      %{status: :ready} = run -> {:existing, :execute, run}
      %{status: :awaiting_approval} = run -> {:existing, :await, run}
      %{status: :running} = run -> {:existing, :busy, run}
      _terminal -> nil
    end
  end

  defp call_from_wire(%{"id" => id, "tool" => tool, "arguments" => arguments}) do
    %ToolCall{id: id, tool: tool, arguments: arguments}
  end

  defp ordered_runs(invocation) do
    invocation
    |> Map.get(:tool_runs, %{})
    |> Map.take(invocation |> Map.get(:tool_run_order, []) |> Enum.reverse())
    |> Map.values()
  end
end
