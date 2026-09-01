defmodule ReyCode.Herdr do
  @moduledoc """
  Best-effort Herdr lifecycle reporter for the terminal UI.

  Herdr exposes a local CLI contract for custom agents. ReyCode reports its
  durable orchestration state only when running inside a Herdr pane; outside
  Herdr this module is inert. Reports are serialized and bounded so a missing
  or unhealthy Herdr server cannot block the TUI.
  """

  use GenServer

  require Logger

  @source "custom:reycode"
  @agent "reycode"
  @command_timeout_ms 1_000

  @type lifecycle_state :: :idle | :working | :blocked
  @type runner :: (String.t(), [String.t()] -> {binary(), non_neg_integer()})

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Reports the current durable Projection state to the Herdr pane."
  @spec report_projection(map(), GenServer.server()) :: :ok
  def report_projection(projection, server \\ __MODULE__) do
    case lifecycle(projection) do
      {:blocked, message} -> report(:blocked, message, server)
      {state, nil} -> report(state, nil, server)
    end
  end

  @doc "Reports one Herdr lifecycle state without affecting ReyCode execution."
  @spec report(lifecycle_state(), String.t() | nil, GenServer.server()) :: :ok
  def report(state, message \\ nil, server \\ __MODULE__)
      when state in [:idle, :working, :blocked] do
    GenServer.cast(server, {:report, state, message})
    :ok
  end

  @doc "Releases ReyCode's Herdr lifecycle authority before TUI shutdown."
  @spec release(GenServer.server()) :: :ok
  def release(server \\ __MODULE__) do
    GenServer.cast(server, :release)
    :ok
  end

  @doc "Returns the Herdr lifecycle state represented by a Projection."
  @spec lifecycle(map()) :: {lifecycle_state(), String.t() | nil}
  def lifecycle(%{invocations: invocations}) when is_map(invocations) do
    invocations = Map.values(invocations)

    cond do
      Enum.any?(invocations, &(&1.status in [:waiting_tool_approval, :waiting_operator])) ->
        {:blocked, "ReyCode is waiting for an operator decision"}

      Enum.any?(invocations, &(&1.status in [:queued, :running, :awaiting_delegation])) ->
        {:working, nil}

      true ->
        {:idle, nil}
    end
  end

  def lifecycle(_projection), do: {:idle, nil}

  @impl true
  def init(opts) do
    {:ok,
     %{
       integration: integration_config(opts),
       runner: Keyword.get(opts, :runner, &run_command/2),
       task_supervisor: Keyword.get(opts, :task_supervisor, ReyCode.ProviderTaskSupervisor),
       sequence: Keyword.get(opts, :sequence, System.system_time(:microsecond)),
       task: nil,
       timer: nil,
       pending: nil,
       last_action: nil
     }}
  end

  @impl true
  def handle_cast({:report, _state, _message}, %{integration: nil} = server_state) do
    {:noreply, server_state}
  end

  def handle_cast({:report, state, message}, server_state) do
    {:noreply, enqueue(server_state, {:report, state, message})}
  end

  def handle_cast(:release, %{integration: nil} = server_state), do: {:noreply, server_state}
  def handle_cast(:release, server_state), do: {:noreply, enqueue(server_state, :release)}

  @impl true
  def handle_info({ref, _result}, %{task: %{ref: ref}} = server_state) do
    {:noreply, finish_task(server_state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = server_state) do
    {:noreply, finish_task(server_state)}
  end

  def handle_info({:herdr_timeout, ref}, %{task: %{ref: ref} = task} = server_state) do
    _ = Task.shutdown(task, :brutal_kill)
    {:noreply, finish_task(server_state)}
  end

  def handle_info(_message, server_state), do: {:noreply, server_state}

  defp enqueue(server_state, action) do
    cond do
      action == server_state.last_action or action == server_state.pending ->
        server_state

      is_nil(server_state.task) ->
        dispatch(server_state, action)

      true ->
        %{server_state | pending: action}
    end
  end

  defp dispatch(%{integration: integration} = server_state, action) do
    sequence = server_state.sequence + 1
    {args, integration} = command(integration, action, sequence)

    task =
      Task.Supervisor.async_nolink(server_state.task_supervisor, fn ->
        server_state.runner.(integration.bin_path, args)
      end)

    timer = Process.send_after(self(), {:herdr_timeout, task.ref}, @command_timeout_ms)

    %{
      server_state
      | integration: integration,
        sequence: sequence,
        task: task,
        timer: timer,
        last_action: action
    }
  end

  defp finish_task(%{timer: timer, pending: nil} = server_state) do
    if timer, do: Process.cancel_timer(timer)
    %{server_state | task: nil, timer: nil}
  end

  defp finish_task(%{timer: timer, pending: action} = server_state) do
    if timer, do: Process.cancel_timer(timer)
    dispatch(%{server_state | task: nil, timer: nil, pending: nil}, action)
  end

  defp command(integration, {:report, state, message}, sequence) do
    args = [
      "pane",
      "report-agent",
      integration.pane_id,
      "--source",
      @source,
      "--agent",
      @agent,
      "--state",
      Atom.to_string(state),
      "--seq",
      Integer.to_string(sequence)
    ]

    args = if is_binary(message), do: args ++ ["--message", message], else: args
    {args, integration}
  end

  defp command(integration, :release, sequence) do
    {
      [
        "pane",
        "release-agent",
        integration.pane_id,
        "--source",
        @source,
        "--agent",
        @agent,
        "--seq",
        Integer.to_string(sequence)
      ],
      integration
    }
  end

  defp integration_config(opts) do
    env = Keyword.get(opts, :env, System.get_env())
    pane_id = env["HERDR_PANE_ID"]
    bin_path = env["HERDR_BIN_PATH"] || System.find_executable("herdr")

    if env["HERDR_ENV"] == "1" and valid_text?(pane_id) and valid_text?(bin_path) do
      %{pane_id: pane_id, bin_path: bin_path}
    end
  end

  defp valid_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp run_command(bin_path, args) do
    System.cmd(bin_path, args, stderr_to_stdout: true)
  rescue
    error ->
      Logger.debug("Herdr lifecycle report failed: #{Exception.message(error)}")
      {"", 1}
  end
end
