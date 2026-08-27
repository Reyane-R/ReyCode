defmodule ReyCode.ProcessHub do
  @moduledoc """
  Supervises bounded named background processes for workspace tools.

  The Hub owns every Port, retained output buffer, restart specification, and
  terminal status. Processes never outlive the Hub. Names are unique while
  running; exited entries remain inspectable until explicitly restarted or
  replaced.
  """

  use GenServer

  alias ReyCode.RuntimeConfig.Tools.BackgroundProcess
  alias ReyCode.Security.Environment

  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @type snapshot :: %{
          name: String.t(),
          command: [String.t()],
          workspace: String.t(),
          status: :running | :exited | :stopped,
          exit_status: non_neg_integer() | nil,
          output_bytes: non_neg_integer(),
          truncated: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @spec start(String.t(), [String.t()], String.t(), BackgroundProcess.t(), GenServer.server()) ::
          {:ok, snapshot()} | {:error, term()}
  def start(name, command, workspace, policy, server \\ __MODULE__) do
    GenServer.call(server, {:start, name, command, workspace, policy})
  end

  @spec logs(String.t(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def logs(name, server \\ __MODULE__), do: GenServer.call(server, {:logs, name})

  @spec list(GenServer.server()) :: [snapshot()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @spec stop(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def stop(name, server \\ __MODULE__), do: GenServer.call(server, {:stop, name})

  @spec await(String.t(), String.t(), pos_integer(), GenServer.server()) ::
          {:ok, map()} | {:error, atom()}
  def await(name, pattern, timeout_ms, server \\ __MODULE__) do
    await_logs(name, pattern, System.monotonic_time(:millisecond) + timeout_ms, server)
  end

  @spec restart(String.t(), GenServer.server()) :: {:ok, snapshot()} | {:error, term()}
  def restart(name, server \\ __MODULE__), do: GenServer.call(server, {:restart, name})

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, ports: %{}}}

  @impl true
  def handle_call({:start, name, command, workspace, policy}, _from, state) do
    case start_entry(state, name, command, workspace, policy) do
      {:ok, entry, next} -> {:reply, {:ok, snapshot(entry)}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:logs, name}, _from, state) do
    case state.entries[name] do
      nil ->
        {:reply, {:error, :process_not_found}, state}

      entry ->
        output = entry.chunks |> :queue.to_list() |> IO.iodata_to_binary() |> text_output()

        {:reply,
         {:ok,
          %{
            "name" => entry.name,
            "status" => Atom.to_string(entry.status),
            "exit_status" => entry.exit_status,
            "output" => output,
            "output_bytes" => entry.output_bytes,
            "truncated" => entry.truncated
          }}, state}
    end
  end

  def handle_call(:list, _from, state) do
    entries = state.entries |> Map.values() |> Enum.sort_by(& &1.name) |> Enum.map(&snapshot/1)
    {:reply, entries, state}
  end

  def handle_call({:stop, name}, _from, state) do
    case state.entries[name] do
      nil ->
        {:reply, {:error, :process_not_found}, state}

      %{status: status} when status != :running ->
        {:reply, :ok, state}

      entry ->
        port = entry.port
        close(port)
        next_entry = %{entry | port: nil, status: :stopped, exit_status: nil}
        next = state |> remove_port(port) |> put_entry(next_entry)
        {:reply, :ok, next}
    end
  end

  def handle_call({:restart, name}, _from, state) do
    case state.entries[name] do
      nil ->
        {:reply, {:error, :process_not_found}, state}

      entry ->
        state = stop_running(state, entry)

        case start_entry(state, name, entry.command, entry.workspace, entry.policy) do
          {:ok, restarted, next} -> {:reply, {:ok, snapshot(restarted)}, next}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      name ->
        entry = append_output(state.entries[name], data)
        {:noreply, put_entry(state, entry)}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      name ->
        entry = state.entries[name]
        next_entry = %{entry | port: nil, status: :exited, exit_status: status}
        next = state |> remove_port(port) |> put_entry(next_entry)
        {:noreply, next}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.ports, fn {port, _name} -> close(port) end)
    :ok
  end

  defp start_entry(state, name, command, workspace, policy) do
    with :ok <- validate_name(name),
         :ok <- validate_command(command),
         :ok <- available_name(state, name),
         :ok <- capacity(state, policy.max_processes),
         {:ok, port} <- open(command, workspace, policy) do
      entry = %{
        name: name,
        command: command,
        workspace: workspace,
        policy: policy,
        port: port,
        status: :running,
        exit_status: nil,
        chunks: :queue.new(),
        output_bytes: 0,
        truncated: false
      }

      next = state |> put_entry(entry) |> put_port(port, name)
      {:ok, entry, next}
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name), do: :ok, else: {:error, :invalid_process_name}
  end

  defp validate_name(_name), do: {:error, :invalid_process_name}

  defp validate_command([executable | args])
       when is_binary(executable) and executable != "" and is_list(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_process_command}
  end

  defp validate_command(_command), do: {:error, :invalid_process_command}

  defp available_name(state, name) do
    case state.entries[name] do
      %{status: :running} -> {:error, :process_name_in_use}
      _entry -> :ok
    end
  end

  defp capacity(state, maximum) do
    count = Enum.count(state.entries, fn {_name, entry} -> entry.status == :running end)
    if count < maximum, do: :ok, else: {:error, :process_limit_reached}
  end

  defp open([command | args], workspace, policy) do
    executable =
      if Path.type(command) == :absolute, do: command, else: System.find_executable(command)

    if is_binary(executable) do
      environment_opts = [
        source: System.get_env(),
        additional_names: policy.env_allowlist,
        cpu_seconds: policy.cpu_seconds,
        open_files: policy.open_files
      ]

      {wrapper, wrapped_args, env} = Environment.wrap(executable, args, environment_opts)

      options = [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, Enum.map(wrapped_args, &String.to_charlist/1)},
        {:cd, String.to_charlist(workspace)},
        {:env,
         Enum.map(env, fn {name, value} ->
           {String.to_charlist(name), String.to_charlist(value)}
         end)}
      ]

      {:ok, Port.open({:spawn_executable, String.to_charlist(wrapper)}, options)}
    else
      {:error, :process_executable_not_found}
    end
  rescue
    error in ErlangError -> {:error, {:process_launch_failed, Exception.message(error)}}
  end

  defp append_output(entry, data) do
    maximum = entry.policy.max_output_bytes
    queue = :queue.in(data, entry.chunks)
    bytes = entry.output_bytes + byte_size(data)
    {queue, bytes, truncated} = trim(queue, bytes, maximum, entry.truncated)
    %{entry | chunks: queue, output_bytes: bytes, truncated: truncated}
  end

  defp trim(queue, bytes, maximum, truncated) when bytes <= maximum,
    do: {queue, bytes, truncated}

  defp trim(queue, bytes, maximum, _truncated) do
    case :queue.out(queue) do
      {{:value, chunk}, rest} when byte_size(chunk) < bytes ->
        trim(rest, bytes - byte_size(chunk), maximum, true)

      {{:value, chunk}, rest} ->
        keep = min(maximum, byte_size(chunk))
        tail = binary_part(chunk, byte_size(chunk) - keep, keep)
        {:queue.in_r(tail, rest), keep, true}

      {:empty, _queue} ->
        {:queue.new(), 0, true}
    end
  end

  defp stop_running(state, %{status: :running} = entry) do
    port = entry.port
    close(port)
    next = %{entry | port: nil, status: :stopped, exit_status: nil}
    state |> remove_port(port) |> put_entry(next)
  end

  defp stop_running(state, _entry), do: state

  defp put_entry(state, entry), do: %{state | entries: Map.put(state.entries, entry.name, entry)}
  defp put_port(state, port, name), do: %{state | ports: Map.put(state.ports, port, name)}
  defp remove_port(state, port), do: %{state | ports: Map.delete(state.ports, port)}

  defp snapshot(entry) do
    %{
      name: entry.name,
      command: entry.command,
      workspace: entry.workspace,
      status: entry.status,
      exit_status: entry.exit_status,
      output_bytes: entry.output_bytes,
      truncated: entry.truncated
    }
  end

  defp await_logs(name, pattern, deadline_ms, server) do
    case logs(name, server) do
      {:ok, %{"output" => output} = result} ->
        cond do
          String.contains?(output, pattern) ->
            {:ok, result}

          result["status"] != "running" ->
            {:error, :process_exited_before_ready}

          true ->
            continue_await(name, pattern, deadline_ms, server)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_await(name, pattern, deadline_ms, server) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :process_wait_timeout}
    else
      receive do
      after
        min(remaining_ms, 10) -> await_logs(name, pattern, deadline_ms, server)
      end
    end
  end

  defp text_output(output) do
    if String.valid?(output), do: output, else: "base64:" <> Base.encode64(output)
  end

  defp close(nil), do: :ok

  defp close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        _ = System.cmd("/bin/kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
        _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port), else: :ok
  rescue
    ArgumentError -> :ok
  end
end
