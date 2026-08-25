defmodule ReyCode.Test.Wait do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.Catalog

  # Subscription registration and the snapshot reply are separate steps, so a
  # broadcast dispatched in between can sit ahead of the baseline in this
  # process's mailbox. Both helpers therefore ignore notifications at or
  # below the version of the baseline they returned.
  def projection(server, matcher, timeout \\ 5_000) do
    baseline = Engine.subscribe(server)

    baseline
    |> match_or_wait(:projection_snapshot, matcher, deadline(timeout), fn value ->
      match?(%{sequence: sequence} when sequence <= baseline.sequence, value)
    end)
  end

  def turn_status(server, turn_id, statuses, timeout \\ 5_000) do
    statuses = List.wrap(statuses)
    projection(server, &turn_with_status(&1, turn_id, statuses), timeout)
  end

  def terminal_turn(server, turn_id, timeout \\ 5_000) do
    turn_status(server, turn_id, :terminal, timeout)
  end

  def invocation_status(server, turn_id, statuses, timeout \\ 5_000) do
    statuses = List.wrap(statuses)
    projection(server, &invocation_with_status(&1, turn_id, statuses), timeout)
  end

  def pending_review(server, turn_id, timeout \\ 5_000) do
    projection(server, &turn_with_pending_review(&1, turn_id), timeout)
  end

  def catalog(server, matcher, timeout \\ 5_000) do
    baseline = Catalog.subscribe(server)

    baseline.providers
    |> match_or_wait(:provider_catalog_updated, matcher, deadline(timeout), fn value ->
      match?(
        %Catalog.Snapshot{generation: generation} when generation <= baseline.generation,
        value
      )
    end)
  end

  def registry_entry(registry, key, timeout \\ 1_000) do
    wait_for_registry(registry, key, deadline(timeout))
  end

  defp match_or_wait(value, message_tag, matcher, deadline, stale?) do
    case matcher.(value) do
      result when result in [false, nil] ->
        wait_for(message_tag, matcher, deadline, stale?)

      result ->
        if message_tag == :provider_catalog_updated, do: drain(message_tag)
        result
    end
  end

  defp wait_for(message_tag, matcher, deadline, stale?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^message_tag, value} ->
        if stale?.(value) do
          wait_for(message_tag, matcher, deadline, stale?)
        else
          payload = unwrap(message_tag, value)
          match_or_wait(payload, message_tag, matcher, deadline, stale?)
        end
    after
      remaining -> flunk("timed out waiting for #{message_tag}")
    end
  end

  defp unwrap(:provider_catalog_updated, %Catalog.Snapshot{} = snapshot), do: snapshot.providers
  defp unwrap(_tag, value), do: value

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp wait_for_registry(registry, key, deadline) do
    case Registry.lookup(registry, key) do
      [entry | _entries] ->
        entry

      [] ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if remaining == 0 do
          flunk("timed out waiting for registry entry #{inspect(key)}")
        else
          Process.sleep(min(remaining, 10))
          wait_for_registry(registry, key, deadline)
        end
    end
  end

  defp turn_with_status(projection, turn_id, statuses) do
    case projection.turns[turn_id] do
      %{status: status, outcome: outcome} = turn ->
        if status in statuses or outcome in statuses, do: turn

      _turn ->
        nil
    end
  end

  defp turn_with_pending_review(projection, turn_id) do
    case projection.turns[turn_id] do
      %{squad: squad} = turn when not is_nil(squad) ->
        if squad.pending_review, do: turn

      _turn ->
        nil
    end
  end

  defp invocation_with_status(projection, turn_id, statuses) do
    case projection.turns[turn_id] do
      nil ->
        nil

      turn ->
        Enum.find_value(
          turn.invocation_order,
          &matching_invocation(projection, &1, statuses)
        )
    end
  end

  defp matching_invocation(projection, invocation_id, statuses) do
    case projection.invocations[invocation_id] do
      %{status: status} = invocation -> if status in statuses, do: invocation
      _invocation -> nil
    end
  end

  defp drain(message_tag) do
    receive do
      {^message_tag, _value} -> drain(message_tag)
    after
      0 -> :ok
    end
  end
end
