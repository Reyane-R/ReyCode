defmodule ReyCode.SquadWaitTest do
  use ExUnit.Case, async: true

  alias ReyCode.SquadWait

  @engine __MODULE__.FakeEngine

  defmodule FakeEngine do
    @moduledoc false

    use GenServer

    def start_link({registry, baseline}),
      do: GenServer.start_link(__MODULE__, {registry, baseline}, name: __MODULE__)

    def init({registry, baseline}), do: {:ok, %{registry: registry, baseline: baseline}}

    def handle_call(:event_registry, _from, state), do: {:reply, state.registry, state}

    def handle_call(:snapshot, _from, state), do: {:reply, state.baseline, state}
  end

  describe "terminal outcomes" do
    test "a turn already terminal at the baseline returns immediately" do
      registry = start_engine(terminal_running_baseline())

      assert {:ok, %{outcome: :completed}} = SquadWait.await("turn-1", engine: @engine)

      # The subscription is cleaned up: nothing arrives after the return.
      broadcast(registry, 9, %{})
      refute_receive {:projection_snapshot, _}, 50
    end

    test "cancelled turns are terminal results, not timeouts" do
      registry =
        start_engine(baseline(4, %{"turn-1" => %{status: :running, squad: %{phase: "build"}}}))

      task = wait_async(registry)

      broadcast(registry, 5, %{"turn-1" => cancelled_turn()})

      assert {:ok, %{outcome: :cancelled}} = Task.await(task)
    end
  end

  test "stale and duplicate notifications never regress observed state" do
    registry = start_engine(baseline(10, %{"turn-1" => running_turn("leader_intake")}))

    task = wait_async(registry)

    broadcast(registry, 3, %{"turn-1" => completed_turn("stale")})
    broadcast(registry, 10, %{"turn-1" => running_turn("leader_intake")})
    broadcast(registry, 11, %{"turn-1" => completed_turn("final")})

    assert {:ok, %{squad: %{phase: "final"}}} = Task.await(task)
  end

  test "an expired monotonic deadline reports a distinct timeout" do
    start_engine(baseline(4, %{"turn-1" => running_turn("plan")}))

    assert {:error, :timed_out} = SquadWait.await("turn-1", engine: @engine, timeout_ms: 30)
  end

  test "phases are announced once per transition" do
    registry = start_engine(baseline(4, %{"turn-1" => running_turn("leader_intake")}))

    parent = self()
    task = wait_async(registry, on_phase: fn phase -> send(parent, {:phase, phase}) end)

    broadcast(registry, 5, %{"turn-1" => running_turn("stories")})
    broadcast(registry, 6, %{"turn-1" => running_turn("stories")})
    broadcast(registry, 7, %{"turn-1" => completed_turn("release_gate")})

    Task.await(task)

    assert_receive {:phase, "stories"}
    assert_receive {:phase, "release_gate"}
    refute_receive {:phase, _}
  end

  test "pending gates fire once per review id" do
    registry = start_engine(baseline(4, %{"turn-1" => running_turn("implementation")}))

    parent = self()
    task = wait_async(registry, on_gate_pending: fn _turn -> send(parent, :gate_pending) end)

    broadcast(registry, 5, %{"turn-1" => gated_turn("review-a")})
    broadcast(registry, 6, %{"turn-1" => gated_turn("review-a")})
    Process.sleep(20)
    assert_received :gate_pending
    refute_received :gate_pending

    broadcast(registry, 7, %{"turn-1" => gated_turn("review-b")})
    broadcast(registry, 8, %{"turn-1" => completed_turn("done")})
    Task.await(task)

    assert_received :gate_pending
  end

  test "waiting leaves no subscription messages behind" do
    registry = start_engine(baseline(4, %{"turn-1" => running_turn("plan")}))

    task = wait_async(registry)
    broadcast(registry, 5, %{"turn-1" => completed_turn("done")})
    broadcast(registry, 6, %{"turn-1" => completed_turn("done")})

    assert {:ok, _turn} = Task.await(task)

    receive do
      {:projection_snapshot, _} -> flunk("subscription leaked a snapshot")
    after
      0 -> :ok
    end
  end

  defp start_engine(baseline) do
    registry = :"squad_wait_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry})
    start_supervised!({FakeEngine, {registry, baseline}})
    registry
  end

  defp terminal_running_baseline do
    baseline(4, %{"turn-1" => completed_turn("release_gate")})
  end

  defp baseline(sequence, turns) do
    %{sequence: sequence, turns: turns, rooms: %{}, room_order: []}
  end

  defp running_turn(phase) do
    %{id: "turn-1", status: :running, outcome: nil, squad: %{phase: phase}}
  end

  defp completed_turn(phase) do
    %{id: "turn-1", status: :terminal, outcome: :completed, squad: %{phase: phase}}
  end

  defp cancelled_turn do
    %{id: "turn-1", status: :terminal, outcome: :cancelled, squad: %{phase: "release_gate"}}
  end

  defp gated_turn(review_id) do
    %{
      id: "turn-1",
      status: :running,
      outcome: nil,
      squad: %{phase: "release_gate", pending_review: %{id: review_id}}
    }
  end

  defp broadcast(registry, sequence, turns) do
    snapshot = %{sequence: sequence, turns: turns, rooms: %{}, room_order: []}

    Registry.dispatch(registry, :orchestration, fn entries ->
      Enum.each(entries, fn {pid, _value} ->
        send(pid, {:projection_snapshot, snapshot})
      end)
    end)
  end

  defp wait_async(registry, opts \\ []) do
    Task.async(fn ->
      SquadWait.await("turn-1", Keyword.merge([engine: @engine], opts))
    end)
    |> tap(fn _task -> await_subscriber!(registry) end)
  end

  # The waiter subscribes inside its own task; block until the Registry
  # reflects that so test broadcasts cannot race the registration.
  defp await_subscriber!(registry, attempts \\ 400)

  defp await_subscriber!(_registry, 0), do: flunk("waiter never subscribed")

  defp await_subscriber!(registry, attempts) do
    case Registry.lookup(registry, :orchestration) do
      [] ->
        Process.sleep(5)
        await_subscriber!(registry, attempts - 1)

      _subscribers ->
        :ok
    end
  end
end
