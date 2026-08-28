defmodule ReyCode.Orchestration.PeerMessaging do
  @moduledoc "Fail-closed addressing and bounds for Invocation PeerMessages."

  alias ReyCode.Orchestration.{Invocation, Projection}

  @tool_name "send_peer"
  @body_max_bytes 8_192
  @message_max_count 32
  @active_statuses [:queued, :running, :waiting_tool_approval, :awaiting_delegation]

  @type rejection ::
          :invalid_arguments
          | :peer_messaging_requires_wave
          | :peer_message_too_large
          | :peer_message_cap_exceeded
          | :unknown_peer
          | :ambiguous_peer
          | :peer_not_active

  @doc "Returns the provider-visible peer-message tool name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Resolves one exact-name active peer in the sender's DelegationWave."
  @spec authorize(Invocation.t(), term(), Projection.t()) ::
          {:ok, Invocation.t(), String.t()} | {:error, rejection()}
  def authorize(sender, arguments, projection) do
    with {:ok, target_name, body} <- parse_arguments(arguments),
         :ok <- in_wave(sender),
         :ok <- body_size(body),
         :ok <- message_cap(sender, projection),
         {:ok, target} <- resolve_target(sender, target_name, projection) do
      {:ok, target, body}
    end
  end

  defp parse_arguments(arguments) when is_map(arguments) do
    keys = arguments |> Map.keys() |> Enum.map(&to_string/1)
    target = Map.get(arguments, "target", Map.get(arguments, :target))
    body = Map.get(arguments, "body", Map.get(arguments, :body))

    if Enum.sort(keys) == ["body", "target"] and is_binary(target) and target != "" and
         is_binary(body) and body != "" do
      {:ok, target, body}
    else
      {:error, :invalid_arguments}
    end
  end

  defp parse_arguments(_arguments), do: {:error, :invalid_arguments}

  defp in_wave(%{delegated_from_invocation_id: parent_id, delegated_from_tool_run_id: run_id})
       when is_binary(parent_id) and is_binary(run_id),
       do: :ok

  defp in_wave(_sender), do: {:error, :peer_messaging_requires_wave}

  defp body_size(body) do
    if byte_size(body) <= @body_max_bytes, do: :ok, else: {:error, :peer_message_too_large}
  end

  defp message_cap(sender, projection) do
    sent_count =
      projection.invocations
      |> Map.values()
      |> Enum.reduce(0, fn invocation, count ->
        count +
          Enum.count(
            invocation.coordination.peer_messages,
            &(&1.sender_invocation_id == sender.id)
          )
      end)

    if sent_count < @message_max_count,
      do: :ok,
      else: {:error, :peer_message_cap_exceeded}
  end

  defp resolve_target(sender, target_name, projection) do
    matches =
      projection.invocations
      |> Map.values()
      |> Enum.filter(fn candidate ->
        candidate.id != sender.id and
          candidate.delegated_from_invocation_id == sender.delegated_from_invocation_id and
          candidate.delegated_from_tool_run_id == sender.delegated_from_tool_run_id and
          candidate.participant.name == target_name
      end)

    case matches do
      [] -> {:error, :unknown_peer}
      [target] when target.status in @active_statuses -> {:ok, target}
      [_target] -> {:error, :peer_not_active}
      _many -> {:error, :ambiguous_peer}
    end
  end
end
