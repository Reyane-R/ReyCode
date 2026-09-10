defmodule ReyCode.VerifiedChange.Coordinator do
  @moduledoc """
  Temporary supervised owner of one interactive verification and its workers.

  Engine death or the total deadline stops owned execution, never restarts it.
  The Engine journals interruption before cancellation and on coordinator DOWN;
  recovery owns the durable block when the Engine itself is unavailable.
  """

  use GenServer, restart: :temporary

  alias ReyCode.Orchestration.Engine
  alias ReyCode.VerifiedChange

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    reference = Process.monitor(state.engine)
    timeout_ms = max(0, state.deadline_ms - System.monotonic_time(:millisecond))
    timer = Process.send_after(self(), :deadline, timeout_ms)

    {:ok,
     %{run: state, engine_monitor: reference, timer: timer, worker: nil, providers: MapSet.new()}}
  end

  @impl true
  def handle_cast(:start, state) do
    coordinator = self()
    run = state.run

    worker =
      Task.async(fn ->
        # Admission completes before the worker can post a Turn or mutate files.
        receive do
          :admitted -> :ok
        after
          5_000 -> exit(:admission_timeout)
        end

        result = VerifiedChange.run_prepared(run)
        send(coordinator, {:finished, result})
      end)

    :ok = GenServer.call(run.engine, {:verified_change_worker, run.session_id, worker.pid})
    send(worker.pid, :admitted)

    {:noreply, %{state | worker: worker}}
  end

  def handle_cast({:own_provider, pid}, state) do
    Process.link(pid)
    {:noreply, %{state | providers: MapSet.put(state.providers, pid)}}
  end

  def handle_cast(:cancel, state), do: {:stop, :shutdown, state}

  @impl true
  def handle_info(:deadline, state) do
    Engine.cancel_verified_change(state.run.session_id, state.run.engine)
    {:stop, :shutdown, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{engine_monitor: ref} = state),
    do: {:stop, :shutdown, state}

  def handle_info({:finished, _result}, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, %{worker: %{pid: pid}} = state),
    do: {:stop, {:execution_exit, reason}, state}

  def handle_info({:EXIT, pid, _reason}, state),
    do: {:noreply, %{state | providers: MapSet.delete(state.providers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Process.cancel_timer(state.timer)
    workers = if state.worker, do: [state.worker.pid | MapSet.to_list(state.providers)], else: []
    monitors = Enum.map(workers, &{&1, Process.monitor(&1)})
    Enum.each(workers, &Process.exit(&1, :shutdown))
    deadline_ms = System.monotonic_time(:millisecond) + 5_000

    Enum.each(monitors, fn {pid, ref} ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        max(0, deadline_ms - System.monotonic_time(:millisecond)) -> Process.exit(pid, :kill)
      end
    end)

    :ok
  end
end
