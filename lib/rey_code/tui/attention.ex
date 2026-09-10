defmodule ReyCode.TUI.Attention do
  @moduledoc """
  Emits one terminal bell when a new durable owner review needs the Operator.

  Projection comparison prevents repeated signals as unrelated events arrive.
  Non-terminal output is silent.
  """

  @doc "Returns newly pending approval request IDs."
  @spec new_approval_ids(map(), map()) :: MapSet.t(String.t())
  def new_approval_ids(previous, current) do
    MapSet.difference(approval_ids(current), approval_ids(previous))
  end

  @doc "Signals the terminal once when the current projection introduces an approval."
  @spec notify(map(), map(), (-> boolean())) :: :ok
  def notify(previous, current, terminal? \\ &terminal?/0) do
    new_reviews = MapSet.difference(verification_ids(current), verification_ids(previous))

    if (MapSet.size(new_approval_ids(previous, current)) > 0 or MapSet.size(new_reviews) > 0) and
         terminal?.() do
      IO.write(:stderr, "\a")
    end

    :ok
  end

  defp verification_ids(%{sessions: sessions}) do
    Enum.reduce(sessions, MapSet.new(), fn
      {_id, %{verified_change_resolution: %{id: id, status: :indeterminate}}}, ids ->
        MapSet.put(ids, {:reconcile, id})

      {_id, %{verified_change: %{id: id, phase: phase}, verified_change_resolution: nil}}, ids
      when phase in ["ready", "blocked"] ->
        MapSet.put(ids, {:verification, id})

      _session, ids ->
        ids
    end)
  end

  defp verification_ids(_projection), do: MapSet.new()

  defp approval_ids(%{invocations: invocations}) when is_map(invocations) do
    Enum.reduce(invocations, MapSet.new(), fn {_id, invocation}, ids ->
      case approval_id(invocation) do
        nil -> ids
        request_id -> MapSet.put(ids, request_id)
      end
    end)
  end

  defp approval_ids(_projection), do: MapSet.new()

  defp approval_id(%{status: :waiting_tool_approval, pending_tool_review: review})
       when is_map(review) do
    case Map.get(review, :request_id, Map.get(review, "request_id")) do
      request_id when is_binary(request_id) -> request_id
      _missing -> nil
    end
  end

  defp approval_id(_invocation), do: nil

  defp terminal? do
    match?({:ok, _columns}, :io.columns(:standard_error))
  end
end
